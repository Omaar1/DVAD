# configure-ch3-gpp.ps1
# Chain 3 entry: plant a Group Policy Preferences (GPP) cpassword for svc_backup in
# SYSVOL (the MS14-025 issue). Any authenticated user can read SYSVOL, find the
# cpassword in Services.xml, and decrypt it with Microsoft's published AES key
# (gpp-decrypt / Get-GPPPassword / nxc -M gpp_password). That yields svc_backup's
# real password -> svc_backup is in Backup Operators -> offline NTDS via SeBackup.
#
# svc_backup needs NO inbound ACE (it is reached via this SYSVOL secret), so SDProp
# protection on Backup Operators members is irrelevant here.

$ErrorActionPreference = "Stop"

. C:\vagrant\sharedscripts\Get-LabConfig.ps1
. C:\vagrant\sharedscripts\Invoke-AsUserTask.ps1
Import-Module C:\vagrant\sharedscripts\PhaseTimer.psm1 -Force

$cfg     = Get-LabConfig
$netbios = $cfg.domain.netbiosName
$adminPw = $cfg.domain.administratorPassword

Start-PhaseTimer -PhaseName "CHAIN 3 - GPP cpassword plant (svc_backup)"

# svc_backup's real password (single source: lab-users.json) so the planted cpassword
# decrypts to a working credential.
$users = Get-Content -Raw "C:\vagrant\provision\variables\lab-users.json" | ConvertFrom-Json
$svcPw = ($users.objects | Where-Object { $_.type -eq "user" -and $_.username -eq "svc_backup" }).password
if (-not $svcPw) { throw "svc_backup not found in lab-users.json" }

# Encrypt to a GPP cpassword: AES-256-CBC with Microsoft's published key (MS14-025),
# zero IV, UTF-16LE plaintext, PKCS7 padding, then Base64.
$key = [byte[]]@(
    0x4e,0x99,0x06,0xe8,0xfc,0xb6,0x6c,0xc9,0xfa,0xf4,0x93,0x10,0x62,0x0f,0xfe,0xe8,
    0xf4,0x96,0xe8,0x06,0xcc,0x05,0x79,0x90,0x20,0x9b,0x09,0xa4,0x33,0xb6,0x6c,0x1b)
$aes = [System.Security.Cryptography.Aes]::Create()
$aes.Key     = $key
$aes.IV      = New-Object byte[] 16
$aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
$aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
$pt  = [System.Text.Encoding]::Unicode.GetBytes($svcPw)
$ct  = $aes.CreateEncryptor().TransformFinalBlock($pt, 0, $pt.Length)
$cpassword = [Convert]::ToBase64String($ct)
$aes.Dispose()

# A GPP that runs a "BackupAgent" Windows service as svc_backup - a realistic place
# to find a domain service-account credential.
$servicesXml = @"
<?xml version="1.0" encoding="utf-8"?>
<NTServices clsid="{2CFB484A-4E96-4b5d-A0B6-093D2F91E6AE}">
  <NTService clsid="{AB6F0B67-341F-4e51-92F9-005FBFBA1A43}" name="BackupAgent" image="2" changed="2025-01-15 10:00:00" uid="{$([guid]::NewGuid().ToString().ToUpper())}">
    <Properties startupType="NOCHANGE" serviceName="BackupAgent" timeout="30" accountName="$netbios\svc_backup" cpassword="$cpassword" />
  </NTService>
</NTServices>
"@
$xmlB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($servicesXml))

# Creating a GPO and writing under SYSVOL needs a real admin token (the WinRM
# provisioner identity cannot), so run it via a one-shot scheduled task.
$inner = @"
Import-Module GroupPolicy
Import-Module ActiveDirectory
`$gpoName = "Backup Agent Service"
`$gpo = Get-GPO -Name `$gpoName -ErrorAction SilentlyContinue
if (-not `$gpo) { `$gpo = New-GPO -Name `$gpoName -Comment "Deploys the backup agent service" }
`$dnsRoot = (Get-ADDomain).DNSRoot
`$svcDir  = "\\`$dnsRoot\SYSVOL\`$dnsRoot\Policies\{`$(`$gpo.Id)}\Machine\Preferences\Services"
New-Item -ItemType Directory -Path `$svcDir -Force | Out-Null
`$bytes = [Convert]::FromBase64String("$xmlB64")
[System.IO.File]::WriteAllBytes("`$svcDir\Services.xml", `$bytes)
Write-Host "[+] GPP cpassword for svc_backup planted at `$svcDir\Services.xml"
"@

if (Invoke-AsUserTask -Name "PlantGppCpassword" -ScriptContent $inner -User "$netbios\Administrator" -Password $adminPw -TimeoutSec 120) {
    Write-Host "[+] Chain 3 GPP cpassword planted (decrypt with gpp-decrypt / Get-GPPPassword)" -ForegroundColor Green
    Stop-PhaseTimer -Status Success
} else {
    Write-Host "[!] GPP cpassword plant failed or timed out" -ForegroundColor Red
    Stop-PhaseTimer -Status Failed
}

Show-InstallationSummary
