# configure-ch4-gpo.ps1
# Chain 4: GPO abuse -> SYSTEM on the DC. Creates a GPO linked to the Domain
# Controllers OU and delegates EDIT rights on it to Project-Phoenix (the misconfig).
# A Project-Phoenix member can then inject an immediate scheduled task / startup
# script (SharpGPOAbuse / pyGPOAbuse) that runs as SYSTEM on the DC = full domain
# compromise. Entry is the Ch8 anon foothold (y.chen is a member of Project-Phoenix).

$ErrorActionPreference = "Stop"

. C:\vagrant\sharedscripts\Get-LabConfig.ps1
. C:\vagrant\sharedscripts\Invoke-AsUserTask.ps1
Import-Module C:\vagrant\sharedscripts\PhaseTimer.psm1 -Force

$cfg     = Get-LabConfig
$netbios = $cfg.domain.netbiosName
$adminPw = $cfg.domain.administratorPassword

Start-PhaseTimer -PhaseName "CHAIN 4 - GPO abuse (Project-Phoenix edits DC-linked GPO)"

# Creating/linking a GPO and delegating permissions needs a real admin token, so run
# it via a one-shot scheduled task (same pattern as the GMSA / dSHeuristics steps).
$inner = @"
Import-Module GroupPolicy
Import-Module ActiveDirectory
`$domainDN = (Get-ADDomain).DistinguishedName
`$gpoName  = "DC Security Baseline"

`$gpo = Get-GPO -Name `$gpoName -ErrorAction SilentlyContinue
if (-not `$gpo) { `$gpo = New-GPO -Name `$gpoName -Comment "Domain controller security baseline" }

# Link to the Domain Controllers OU: editing this GPO = code exec as SYSTEM on the DC.
`$dcOU = "OU=Domain Controllers,`$domainDN"
try   { New-GPLink -Name `$gpoName -Target `$dcOU -LinkEnabled Yes -ErrorAction Stop | Out-Null }
catch { Set-GPLink  -Name `$gpoName -Target `$dcOU -LinkEnabled Yes -ErrorAction SilentlyContinue | Out-Null }

# THE MISCONFIG: delegate full edit rights on this DC-linked GPO to Project-Phoenix.
Set-GPPermission -Name `$gpoName -TargetName "Project-Phoenix" -TargetType Group -PermissionLevel GpoEditDeleteModifySecurity -Replace | Out-Null

Write-Host "[+] '`$gpoName' linked to Domain Controllers OU; EDIT delegated to Project-Phoenix"
"@

if (Invoke-AsUserTask -Name "ConfigureCh4Gpo" -ScriptContent $inner -User "$netbios\Administrator" -Password $adminPw -TimeoutSec 120) {
    Write-Host "[+] Chain 4 GPO abuse configured (Project-Phoenix -> DC GPO -> SYSTEM on DC)" -ForegroundColor Green
    Stop-PhaseTimer -Status Success
} else {
    Write-Host "[!] Chain 4 GPO setup failed or timed out" -ForegroundColor Red
    Stop-PhaseTimer -Status Failed
}

Show-InstallationSummary
