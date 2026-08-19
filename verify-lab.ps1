# verify-lab.ps1
# Post-provisioning health check for DVAD. Tests IP reachability, WinRM, expected
# service state, and domain membership for the VMs in a deployment profile.
#
# Profile-aware on purpose: the previous version hardcoded all four VMs, so a
# 'core' build (DC + member server) reported two false PING failures for CA01 and
# CM01 - VMs it was never asked to create. The VM list and the expected services
# both come from inventory/lab-config.json via the shared planner.
#
# Exit code 0 when every check passes, 1 otherwise.
#
#   .\verify-lab.ps1                    # the default profile
#   .\verify-lab.ps1 -Profile full
#   .\verify-lab.ps1 -Only CA01

[CmdletBinding()]
param(
    [Alias('Profile')]
    [string]   $LabProfile,
    [string[]] $Only
)

Import-Module (Join-Path $PSScriptRoot 'tools\lab\plan.psm1') -Force

$plan = New-LabPlan -ProfileName $LabProfile -Only $Only
$cfg  = $plan.Config

$pass = ConvertTo-SecureString $cfg.domain.administratorPassword -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential(
    "$($cfg.domain.netbiosName)\Administrator", $pass)

$PASS = 0; $FAIL = 0

function ok   { param($m) $script:PASS++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function no   { param($m) $script:FAIL++; Write-Host "  [FAIL] $m" -ForegroundColor Red }

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host " DVAD Health Check - profile '$($plan.ProfileName)'" -ForegroundColor Cyan
Write-Host " $($plan.VmNames.Count) VM(s): $($plan.VmNames -join ', ')" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan

foreach ($key in $plan.HostKeys) {
    $h = $cfg.hosts.$key

    Write-Host ""
    Write-Host "--- $($h.name) ($($h.ip)) ---" -ForegroundColor Yellow

    if (-not (Test-Connection -ComputerName $h.ip -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
        no "$($h.name) unreachable at $($h.ip) - VM may be down"
        continue
    }
    ok "$($h.name) responds to ping"

    try {
        $session = New-PSSession -ComputerName $h.ip -Credential $cred `
            -SessionOption (New-PSSessionOption -SkipCACheck -SkipCNCheck) `
            -Authentication Basic -ErrorAction Stop
    } catch {
        no "$($h.name) WinRM failed - $_"
        continue
    }
    ok "$($h.name) WinRM connected"

    try {
        # Expected services come from lab-config.json, not a table in this file.
        foreach ($svc in @($h.services)) {
            $state = Invoke-Command -Session $session -ScriptBlock {
                param($s)
                $x = Get-Service -Name $s -ErrorAction SilentlyContinue
                if ($x) { $x.Status.ToString() } else { 'NotFound' }
            } -ArgumentList $svc

            if ($state -eq 'Running') { ok "$($h.name) service $svc running" }
            else                      { no "$($h.name) service $svc is $state" }
        }

        # Domain membership. Proves an actual join rather than just "a Windows box
        # answered" - the old check looked at the Workstation service, which runs
        # on every Windows machine and therefore proved nothing.
        $joined = Invoke-Command -Session $session -ScriptBlock {
            (Get-CimInstance Win32_ComputerSystem).Domain
        }
        if ($joined -eq $cfg.domain.fqdn) { ok "$($h.name) joined to $joined" }
        else { no "$($h.name) domain is '$joined', expected '$($cfg.domain.fqdn)'" }
    } finally {
        Remove-PSSession $session -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host (" PASS: {0}   FAIL: {1}" -f $PASS, $FAIL) -ForegroundColor $(if ($FAIL -eq 0) { 'Green' } else { 'Red' })
if ($FAIL -eq 0) {
    Write-Host " Lab is healthy" -ForegroundColor Green
} else {
    Write-Host " Review the failures above" -ForegroundColor Red
}
Write-Host "======================================" -ForegroundColor Cyan

if ($FAIL -gt 0) { exit 1 } else { exit 0 }
