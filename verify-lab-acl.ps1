# verify-lab-acl.ps1
# Ground-truth, full-chain validation of the DVAD attack paths. Run in an
# elevated PowerShell ON the root DC after the lab is fully provisioned (all VMs joined).
# Reads real directory state (ACEs by SID+rights+GUID, group membership, GPOs, SYSVOL,
# dSHeuristics) - no attacker tooling, no string-grep guesswork.
# Exit code 0 if no FAIL, 1 otherwise.

Import-Module ActiveDirectory
Import-Module GroupPolicy -ErrorAction SilentlyContinue

. "$PSScriptRoot\sharedscripts\get-lab-config.ps1"
$cfg      = Get-LabConfig
$svr1Name = $cfg.hosts.svr1.name
$adcsName = $cfg.hosts.adcs.name

$dn      = (Get-ADDomain).DistinguishedName
$dnsRoot = (Get-ADDomain).DNSRoot
$usersJson = "C:\vagrant\provision\variables\lab-users.json"
$PASS = 0; $FAIL = 0; $SKIP = 0

function ok([string]$m)  { $script:PASS++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function no([string]$m)  { $script:FAIL++; Write-Host "  [FAIL] $m" -ForegroundColor Red }
function skip([string]$m){ $script:SKIP++; Write-Host "  [SKIP] $m" -ForegroundColor Yellow }
function chk([string]$m,[bool]$c){ if ($c) { ok $m } else { no $m } }
function head([string]$m){ Write-Host "`n== $m ==" -ForegroundColor Cyan }

function Resolve-Sid($n){
    $o = Get-ADObject -LDAPFilter "(|(sAMAccountName=$n)(sAMAccountName=$n`$))" -Properties objectSid -EA SilentlyContinue | Select-Object -First 1
    if ($o) { $o.objectSid.Value } else { $null }
}
function Test-Ace($Principal,$TargetDN,[System.DirectoryServices.ActiveDirectoryRights]$Right,[guid]$ObjType=[guid]::Empty){
    $psid = Resolve-Sid $Principal
    if (-not $psid) { return $false }
    foreach ($a in (Get-Acl "AD:\$TargetDN").Access) {
        try { $asid = $a.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { $asid = $a.IdentityReference.Value }
        if ($asid -ne $psid) { continue }
        if ((([int]$a.ActiveDirectoryRights) -band ([int]$Right)) -ne ([int]$Right)) { continue }
        if ($a.ObjectType -ne $ObjType) { continue }
        return $true
    }
    return $false
}
function In-Group($member,$group){
    try { [bool](Get-ADGroupMember $group -Recursive -EA Stop | Where-Object { $_.SamAccountName -eq $member }) } catch { $false }
}
function User-Pw($name){
    ((Get-Content -Raw $usersJson | ConvertFrom-Json).objects | Where-Object { $_.type -eq 'user' -and $_.username -eq $name }).password
}

$G_REPL = '1131f6aa-9c07-11d1-f79f-00c04fc2dcd2'
$G_RALL = '1131f6ad-9c07-11d1-f79f-00c04fc2dcd2'

head "Chain 1 - Kerberoast (svc_sqldb)"
chk "svc_sqldb has SPN"            ([bool](Get-ADUser svc_sqldb -Properties ServicePrincipalName).ServicePrincipalName)
chk "svc_sqldb in Domain Admins"   (In-Group 'svc_sqldb' 'Domain Admins')

head "Chain 2 - AS-REP + Shadow Creds -> Account Operators"
chk "j.martinez DoesNotRequirePreAuth" ((Get-ADUser j.martinez -Properties DoesNotRequirePreAuth).DoesNotRequirePreAuth)
chk "GenericWrite j.martinez -> r.chen (survived SDProp)" (Test-Ace 'j.martinez' (Get-ADUser r.chen).DistinguishedName GenericWrite)
chk "r.chen in Account Operators"  (In-Group 'r.chen' 'Account Operators')
chk "r.chen NOT re-protected (adminCount != 1)" (((Get-ADUser r.chen -Properties adminCount).adminCount) -ne 1)

head "Chain 3 - GPP cpassword -> Backup Operators"
chk "svc_backup in Backup Operators" (In-Group 'svc_backup' 'Backup Operators')
$svcXml = Get-ChildItem "\\$dnsRoot\SYSVOL\$dnsRoot\Policies" -Recurse -Filter Services.xml -EA SilentlyContinue | Select-Object -First 1
if ($svcXml) {
    $cpw   = ([regex]'cpassword="([^"]*)"').Match((Get-Content -Raw $svcXml.FullName)).Groups[1].Value
    $usrPw = User-Pw 'svc_backup'
    $dec = ""
    try {
        $key = [byte[]]@(0x4e,0x99,0x06,0xe8,0xfc,0xb6,0x6c,0xc9,0xfa,0xf4,0x93,0x10,0x62,0x0f,0xfe,0xe8,0xf4,0x96,0xe8,0x06,0xcc,0x05,0x79,0x90,0x20,0x9b,0x09,0xa4,0x33,0xb6,0x6c,0x1b)
        $b = $cpw + ('=' * ((4 - ($cpw.Length % 4)) % 4))
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.Key = $key; $aes.IV = New-Object byte[] 16
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $ctb = [Convert]::FromBase64String($b)
        $dec = [System.Text.Encoding]::Unicode.GetString($aes.CreateDecryptor().TransformFinalBlock($ctb,0,$ctb.Length))
        $aes.Dispose()
    } catch {}
    chk "GPP Services.xml present with cpassword" ([bool]$cpw)
    chk "cpassword decrypts to svc_backup's real password" ($dec -eq $usrPw)
} else {
    no "GPP Services.xml not found in SYSVOL"
}

head "Chain 4 - GPO abuse (Project-Phoenix -> DC-linked GPO)"
$gpoName = "DC Security Baseline"
$gpo = Get-GPO -Name $gpoName -EA SilentlyContinue
chk "GPO '$gpoName' exists" ([bool]$gpo)
if ($gpo) {
    $linked = (Get-GPInheritance -Target "OU=Domain Controllers,$dn").GpoLinks | Where-Object { $_.DisplayName -eq $gpoName }
    chk "GPO linked to Domain Controllers OU" ([bool]$linked)
    $perm = Get-GPPermission -Name $gpoName -TargetName "Project-Phoenix" -TargetType Group -EA SilentlyContinue
    chk "Project-Phoenix has edit on the GPO" ([bool]($perm -and $perm.Permission -match 'Edit'))
}
chk "y.chen in Project-Phoenix (Ch8->Ch4 link)" (In-Group 'y.chen' 'Project-Phoenix')

head "Chain 5 - gMSA -> DCSync"
chk "WriteOwner d.patel -> GMSA-Readers" (Test-Ace 'd.patel' (Get-ADGroup GMSA-Readers).DistinguishedName WriteOwner)
chk "gmsa_svc exists" ([bool](Get-ADServiceAccount gmsa_svc -EA SilentlyContinue))
chk "DCSync repl gmsa_svc -> domain root"     (Test-Ace 'gmsa_svc' $dn ExtendedRight $G_REPL)
chk "DCSync repl-all gmsa_svc -> domain root" (Test-Ace 'gmsa_svc' $dn ExtendedRight $G_RALL)

head "Chain 6 - Delegation (set by configure-machine-attacks.ps1 on the member server)"
$svr1 = Get-ADComputer $svr1Name -Properties TrustedForDelegation -EA SilentlyContinue
$adcsC = Get-ADComputer $adcsName -EA SilentlyContinue
if ($svr1) {
    chk "$svr1Name unconstrained (TrustedForDelegation)" ($svr1.TrustedForDelegation)
    $web = Get-ADUser svc_web -Properties 'msDS-AllowedToDelegateTo',TrustedToAuthForDelegation
    chk "svc_web constrained delegation set" ([bool]$web.'msDS-AllowedToDelegateTo')
    chk "svc_web protocol transition"        ($web.TrustedToAuthForDelegation)
    if ($adcsC) { chk "GenericWrite l.garcia -> $adcsName`$ (RBCD target)" (Test-Ace 'l.garcia' $adcsC.DistinguishedName GenericWrite) }
    else        { skip "$adcsName computer not joined yet" }
} else {
    skip "$svr1Name not joined yet - Chain 6 ($svr1Name/svc_web/l.garcia) is applied last on the member server; re-run after it finishes"
}
chk "MachineAccountQuota = 10 (RBCD: attacker can add a computer)" (((Get-ADObject $dn -Properties 'ms-DS-MachineAccountQuota').'ms-DS-MachineAccountQuota') -eq 10)

head "Chain 7 - LAPS (set by configure-machine-attacks.ps1 on the member server)"
if ($svr1) {
    chk "AllExtendedRights t.brown -> $svr1Name`$" (Test-Ace 't.brown' $svr1.DistinguishedName ExtendedRight ([guid]::Empty))
    chk "$svr1Name ms-Mcs-AdmPwd planted" ([bool](Get-ADComputer $svr1Name -Properties 'ms-Mcs-AdmPwd').'ms-Mcs-AdmPwd')
} else {
    skip "$svr1Name not joined yet - Chain 7 is applied last on the member server; re-run after it finishes"
}

head "Chain 8 - Anonymous bind -> description leak"
$dh = (Get-ADObject "CN=Directory Service,CN=Windows NT,CN=Services,CN=Configuration,$dn" -Properties dSHeuristics).dSHeuristics
chk "dSHeuristics char-7 = 2 (anon bind)"                      ($dh -and $dh.Length -ge 7  -and $dh[6]  -eq '2')
chk "dSHeuristics char-16 = 1 (Account Operators SDProp-excluded)" ($dh -and $dh.Length -ge 16 -and $dh[15] -eq '1')
chk "ANONYMOUS LOGON has read on domain head" ([bool]((Get-Acl "AD:\$dn").Access | Where-Object { $_.IdentityReference -like '*ANONYMOUS LOGON*' -and $_.ActiveDirectoryRights -match 'Read' }))
$ycDesc = (Get-ADUser y.chen -Properties description).description
$ycPw   = User-Pw 'y.chen'
chk "y.chen description leaks her password" ([bool]($ycDesc -and $ycPw -and $ycDesc.Contains($ycPw)))

Write-Host "`n== Summary ==" -ForegroundColor Cyan
Write-Host ("  PASS: {0}   FAIL: {1}   SKIP: {2}" -f $PASS, $FAIL, $SKIP) -ForegroundColor $(if ($FAIL -eq 0) { 'Green' } else { 'Red' })
if ($FAIL -gt 0) { exit 1 } else { exit 0 }
