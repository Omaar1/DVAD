# install-laps-schema.ps1
# ------------------------------------------------------------------------------
# Extends the AD schema with the legacy LAPS attributes (ms-Mcs-AdmPwd,
# ms-Mcs-AdmPwdExpirationTime) using Microsoft's official AdmPwd.PS module,
# installed from the committed LAPS MSI. Replaces the hand-rolled attributeSchema
# construction that previously lived in configure-attack-paths.ps1.
#
# Runs on the Root DC (the schema master). Schema writes need a real Schema-Admin
# logon token, so Update-AdmPwdADSchema runs via a one-shot scheduled task
# (Invoke-AsUserTask) as the domain Administrator, not the local WinRM identity.
#
# SRV01's ms-Mcs-AdmPwd value is planted later by configure-machine-attacks.ps1,
# once SRV01 has joined the domain (it does not exist yet at this point).
#
# Idempotent: skips install + extension if ms-Mcs-AdmPwd is already in the schema.
# ------------------------------------------------------------------------------

$ErrorActionPreference = "Stop"

. C:\vagrant\provisioners\get-lab-config.ps1
. C:\vagrant\provisioners\invoke-as-user-task.ps1
Import-Module C:\vagrant\provisioners\phase-timer.psm1 -Force

$cfg     = Get-LabConfig
$netbios = $cfg.domain.netbiosName
$adminPw = $cfg.domain.administratorPassword
$lapsMsi = "C:\vagrant\provisioners\domain\LAPS\LAPS.x64.msi"

Start-PhaseTimer -PhaseName "LAPS SCHEMA EXTENSION (AdmPwd.PS)"

Import-Module ActiveDirectory -ErrorAction Stop
$schemaNC = (Get-ADRootDSE).schemaNamingContext
$existing = Get-ADObject -SearchBase $schemaNC -Filter { lDAPDisplayName -eq "ms-Mcs-AdmPwd" } -ErrorAction SilentlyContinue

if ($existing) {
    Write-Host " [SKIP] ms-Mcs-AdmPwd already present in schema; nothing to do." -ForegroundColor DarkGray
    Stop-PhaseTimer -Status Success
}
else {
    # 1. Install the AdmPwd.PS management module from the committed MSI. The local
    #    WinRM identity is a local admin, which is enough for a per-machine msiexec.
    if (-not (Test-Path $lapsMsi)) {
        Stop-PhaseTimer -Status Failed
        throw "LAPS MSI not found at $lapsMsi"
    }

    Write-Host " [*] Installing AdmPwd.PS from $lapsMsi ..."
    $msiArgs = "/i `"$lapsMsi`" ADDLOCAL=Management,Management.PS /qn /norestart"
    $proc    = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru
    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
        Stop-PhaseTimer -Status Failed
        throw "LAPS MSI install failed (exit $($proc.ExitCode))."
    }
    Write-Host " [OK] AdmPwd.PS installed." -ForegroundColor Green

    # 2. Extend the schema under a real Schema-Admin token. The WinRM identity
    #    cannot write the schema NC ("Access is denied"), so this runs as the
    #    domain Administrator via a one-shot scheduled task on this DC.
    $schemaScript = @'
$ErrorActionPreference = "Stop"
Import-Module AdmPwd.PS -ErrorAction SilentlyContinue
if (-not (Get-Module AdmPwd.PS)) {
    $psd1 = Get-ChildItem 'C:\Program Files\LAPS' -Recurse -Filter 'AdmPwd.PS.psd1' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $psd1) { throw "AdmPwd.PS module not found after MSI install." }
    Import-Module $psd1.FullName -ErrorAction Stop
}
Update-AdmPwdADSchema
Write-Host "Update-AdmPwdADSchema completed."
'@

    if (Invoke-AsUserTask -Name "LapsSchema" -ScriptContent $schemaScript -User "$netbios\Administrator" -Password $adminPw -TimeoutSec 180) {
        Write-Host " [OK] LAPS schema extended (ms-Mcs-AdmPwd registered)." -ForegroundColor Green
        Stop-PhaseTimer -Status Success
    }
    else {
        Stop-PhaseTimer -Status Failed
        throw "LAPS schema extension failed (see LapsSchema log above)."
    }
}

Show-InstallationSummary
