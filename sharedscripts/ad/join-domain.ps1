#
# OU is the optional path prefix, e.g. OU=Servers
#
param(
    [string] $ou = "default"
)

# Joins this machine to the domain defined in lab-config.json (optionally into -ou).
#
# NB the actual Add-Computer runs via PsExec -s (as SYSTEM), not directly. Vagrant's
# WinRM provisioner runs under a network-logon token, and NetJoinDomain fails there
# with 0x57 "The parameter is incorrect" (the same command in a local session works).
# SYSTEM is a full, non-network token with no logon-right/UAC restrictions, so the
# join succeeds; the domain credential is passed explicitly to Add-Computer.

. C:\vagrant\sharedscripts\Get-LabConfig.ps1
Import-Module C:\vagrant\sharedscripts\PhaseTimer.psm1 -Force
$cfg    = Get-LabConfig
$domain = $cfg.domain
$dcIp   = $cfg.hosts.rootdc.ip

Start-PhaseTimer -PhaseName "DOMAIN JOIN ($($domain.fqdn))"

# Idempotency: if already domain-joined, do nothing (lets re-provisioning succeed).
$cs = Get-WmiObject Win32_ComputerSystem
if ($cs.PartOfDomain) {
    Write-Host "Already joined to domain '$($cs.Domain)'. Skipping."
    Stop-PhaseTimer -Status Success
    Show-InstallationSummary
    exit 0
}

Write-Host "Joining domain: $($domain.fqdn)"
Write-Host "Domain controller to be used as DNS: $dcIp"

# Point DNS at the domain controller.
$adapters = Get-WmiObject Win32_NetworkAdapterConfiguration
if ($adapters) {
    $adapters | ForEach-Object {
        $r = $_.SetDNSServerSearchOrder($dcIp)
        if ($r.ReturnValue -ne 0) {
            Write-Warning "DNS set failed on NIC '$($_.Description)' (code $($r.ReturnValue))"
        }
    }
}

$ouArg = ""
if ($ou -ne "default") { $ouArg = " -OUPath '$ou,$($domain.dn)'" }

# Inner script that performs the join; run under the elevated interactive logon.
$inner = @"
try {
    `$cred = New-Object System.Management.Automation.PSCredential('$($domain.netbiosName)\Administrator', (ConvertTo-SecureString '$($domain.administratorPassword)' -AsPlainText -Force))
    Add-Computer -DomainName '$($domain.fqdn)' -Credential `$cred$ouArg -ErrorAction Stop
    Write-Output 'JOIN OK'
    exit 0
} catch {
    Write-Output ('JOIN ERROR: ' + `$_.Exception.Message)
    exit 1
}
"@
$innerPath = "C:\join-inner.ps1"
$inner | Out-File -FilePath $innerPath -Encoding ASCII

$psexec = "C:\vagrant\sharedscripts\windows\PsExec64.exe"
Write-Host "Joining computer (PsExec as SYSTEM)..."
& $psexec -accepteula -nobanner -s powershell -NoProfile -ExecutionPolicy Bypass -File $innerPath
$rc = $LASTEXITCODE
Remove-Item $innerPath -Force -ErrorAction SilentlyContinue

if ($rc -ne 0) {
    throw "Domain join failed (PsExec/Add-Computer exit $rc). See 'JOIN ERROR' line above."
}
Write-Host "Computer joined to $($domain.fqdn)."

Stop-PhaseTimer -Status Success
Show-InstallationSummary
exit 0
