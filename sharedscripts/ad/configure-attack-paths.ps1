# configure-attack-paths.ps1
# Configures realistic AD attack paths for the SilentRUN-Lab red team environment.
# Run on RootDC AFTER create-ad-objects.ps1 has created all users/groups.
#
# Attack Chains:
#   1. Kerberoasting DA           (svc_sqldb)
#   2. AS-REP Roast -> chain -> DA (j.martinez -> r.chen -> Server-Admins -> DA)
#   3. GenericAll -> Kerberoast    (a.johnson -> Helpdesk-Operators -> svc_backup)
#   4. ForceChangePassword chain  (m.wilson -> k.lee -> Project-Phoenix -> EA)
#   5. WriteOwner -> GMSA -> DCSync(d.patel -> GMSA-Readers -> gmsa_svc$ -> DC)
#   6. Delegation attacks         (Unconstrained/Constrained/RBCD - configured in configure-machine-attacks.ps1)
#   7. AllExtendedRights -> LAPS   (t.brown -> SVR1$)

Import-Module ActiveDirectory -ErrorAction Stop

$domainDN  = (Get-ADDomain).DistinguishedName
$domainDNS = (Get-ADDomain).DNSRoot

$adminPw  = (Get-Content -Raw -Path "C:\vagrant\provision\variables\forest-variables.json" | ConvertFrom-Json).administratorPassword
$netbios  = (Get-Content -Raw -Path "C:\vagrant\provision\variables\forest-variables.json" | ConvertFrom-Json).netbiosName

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Configuring Attack Paths" -ForegroundColor Cyan
Write-Host " Domain: $domainDNS ($domainDN)" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

# ============================================================================
# HELPER: Set ACE on an AD object
# ============================================================================
function Set-ADObjectACE {
    param(
        [string]$TargetDN,
        [string]$PrincipalSAM,
        [string]$RightType,
        [System.DirectoryServices.ActiveDirectorySecurityInheritance]$Inheritance = 'None'
    )

    $target    = [ADSI]"LDAP://$TargetDN"
    $principal = New-Object System.Security.Principal.NTAccount($domainDNS, $PrincipalSAM)
    $sid       = $principal.Translate([System.Security.Principal.SecurityIdentifier])

    $guidMap = @{
        'User-Force-Change-Password' = [GUID]'00299570-246d-11d0-a768-00aa006e0529'
        'Self-Membership'            = [GUID]'bf9679c0-0de6-11d0-a285-00aa003049e2'
        'All-Extended-Rights'        = [GUID]'00000000-0000-0000-0000-000000000000'
    }

    $acl   = $target.psbase.ObjectSecurity
    $allow = [System.Security.AccessControl.AccessControlType]::Allow

    switch ($RightType) {
        'GenericAll' {
            $rights = [System.DirectoryServices.ActiveDirectoryRights]::GenericAll
            $ace    = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($sid, $rights, $allow, $Inheritance)
        }
        'GenericWrite' {
            $rights = [System.DirectoryServices.ActiveDirectoryRights]::GenericWrite
            $ace    = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($sid, $rights, $allow, $Inheritance)
        }
        'WriteDacl' {
            $rights = [System.DirectoryServices.ActiveDirectoryRights]::WriteDacl
            $ace    = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($sid, $rights, $allow, $Inheritance)
        }
        'WriteOwner' {
            $rights = [System.DirectoryServices.ActiveDirectoryRights]::WriteOwner
            $ace    = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($sid, $rights, $allow, $Inheritance)
        }
        'WriteProperty' {
            $rights = [System.DirectoryServices.ActiveDirectoryRights]::WriteProperty
            $ace    = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($sid, $rights, $allow, $Inheritance)
        }
        'ForceChangePassword' {
            $ace = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
                $sid,
                [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight,
                $allow,
                $guidMap['User-Force-Change-Password'],
                $Inheritance
            )
        }
        'Self-Membership' {
            $ace = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
                $sid,
                [System.DirectoryServices.ActiveDirectoryRights]::Self,
                $allow,
                $guidMap['Self-Membership'],
                $Inheritance
            )
        }
        'AllExtendedRights' {
            $ace = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
                $sid,
                [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight,
                $allow,
                $guidMap['All-Extended-Rights'],
                $Inheritance
            )
        }
    }

    $acl.AddAccessRule($ace)
    $target.psbase.CommitChanges()

    Write-Host "  [ACL] $PrincipalSAM -> $RightType on $(($TargetDN -split ',')[0])" -ForegroundColor DarkYellow
}

# ============================================================================
# CHAIN 1: Kerberoasting -> Domain Admin
# svc_sqldb already has SPN (from lab-users.json) and is in Domain Admins.
# Password "Passw0rd" is intentionally weak/crackable.
# ============================================================================
Write-Host ""
Write-Host "[Chain 1] Kerberoasting - svc_sqldb (DA with weak SPN password)" -ForegroundColor Green
$svcSql = Get-ADUser svc_sqldb -Properties ServicePrincipalName
Write-Host "  SPN: $($svcSql.ServicePrincipalName -join ', ')"
Write-Host "  Groups: Domain Admins, DB-Admins"
Write-Host "  [OK] Kerberoastable Domain Admin ready" -ForegroundColor Green

# ============================================================================
# CHAIN 2: AS-REP Roast -> GenericWrite -> WriteOwner -> WriteDACL -> DA
# j.martinez (AS-REP) -> GenericWrite on r.chen -> r.chen WriteOwner on Server-Admins
# -> Server-Admins WriteDACL on Domain Admins
# ============================================================================
Write-Host ""
Write-Host "[Chain 2] AS-REP Roast chain (j.martinez -> r.chen -> Server-Admins -> DA)" -ForegroundColor Green

Set-ADAccountControl -Identity "j.martinez" -DoesNotRequirePreAuth $true
Write-Host "  [AS-REP] j.martinez: DoesNotRequirePreAuth = True" -ForegroundColor Yellow

$rchenDN = (Get-ADUser r.chen).DistinguishedName
Set-ADObjectACE -TargetDN $rchenDN -PrincipalSAM "j.martinez" -RightType "GenericWrite"

$serverAdminsDN = (Get-ADGroup "Server-Admins").DistinguishedName
Set-ADObjectACE -TargetDN $serverAdminsDN -PrincipalSAM "r.chen" -RightType "WriteOwner"

$daGroupDN = (Get-ADGroup "Domain Admins").DistinguishedName
Set-ADObjectACE -TargetDN $daGroupDN -PrincipalSAM "Server-Admins" -RightType "WriteDacl"

Write-Host "  [OK] AS-REP -> GenericWrite -> WriteOwner -> WriteDACL chain ready" -ForegroundColor Green

# ============================================================================
# CHAIN 3: GenericAll on Group -> GenericWrite on Service Account -> NTDS dump
# a.johnson -> GenericAll on Helpdesk-Operators -> Helpdesk-Operators GenericWrite on svc_backup
# -> svc_backup is in Backup Operators (can dump NTDS)
# ============================================================================
Write-Host ""
Write-Host "[Chain 3] GenericAll chain (a.johnson -> Helpdesk-Operators -> svc_backup)" -ForegroundColor Green

$helpdeskDN = (Get-ADGroup "Helpdesk-Operators").DistinguishedName
Set-ADObjectACE -TargetDN $helpdeskDN -PrincipalSAM "a.johnson" -RightType "GenericAll"

$svcBackupDN = (Get-ADUser "svc_backup").DistinguishedName
Set-ADObjectACE -TargetDN $svcBackupDN -PrincipalSAM "Helpdesk-Operators" -RightType "GenericWrite"

Add-ADGroupMember -Identity "Backup Operators" -Members "svc_backup" -ErrorAction SilentlyContinue
Write-Host "  [GROUP] svc_backup added to Backup Operators"
Write-Host "  [OK] GenericAll -> GenericWrite -> Backup Operators chain ready" -ForegroundColor Green

# ============================================================================
# CHAIN 4: ForceChangePassword -> Self/AddMember -> WriteDACL -> Enterprise Admin
# m.wilson -> ForceChangePassword on k.lee -> k.lee Self-Membership on Project-Phoenix
# -> Project-Phoenix WriteDACL on Enterprise Admins
# ============================================================================
Write-Host ""
Write-Host "[Chain 4] ForceChangePassword chain (m.wilson -> k.lee -> Project-Phoenix -> EA)" -ForegroundColor Green

$kleeDN = (Get-ADUser "k.lee").DistinguishedName
Set-ADObjectACE -TargetDN $kleeDN -PrincipalSAM "m.wilson" -RightType "ForceChangePassword"

$projPhoenixDN = (Get-ADGroup "Project-Phoenix").DistinguishedName
Set-ADObjectACE -TargetDN $projPhoenixDN -PrincipalSAM "k.lee" -RightType "Self-Membership"

$eaGroupDN = (Get-ADGroup "Enterprise Admins").DistinguishedName
Set-ADObjectACE -TargetDN $eaGroupDN -PrincipalSAM "Project-Phoenix" -RightType "WriteDacl"

Write-Host "  [OK] ForceChangePassword -> Self-Membership -> WriteDACL chain ready" -ForegroundColor Green

# ============================================================================
# CHAIN 5: WriteOwner -> ReadGMSAPassword -> GenericAll on DC -> DCSync
# d.patel -> WriteOwner on GMSA-Readers -> GMSA-Readers can read gmsa_svc$ password
# -> gmsa_svc$ has DS-Replication rights (DCSync)
# ============================================================================
Write-Host ""
Write-Host "[Chain 5] GMSA/DCSync chain (d.patel -> GMSA-Readers -> gmsa_svc$ -> DC)" -ForegroundColor Green

$gmsaScript = @"
Import-Module ActiveDirectory
`$domainDNS = (Get-ADDomain).DNSRoot
`$domainDN  = (Get-ADDomain).DistinguishedName

`$kds = Get-KdsRootKey -ErrorAction SilentlyContinue
if (-not `$kds) {
    Add-KdsRootKey -EffectiveTime ((Get-Date).AddHours(-10)) | Out-Null
}

`$gmsaExists = Get-ADServiceAccount -Filter { Name -eq "gmsa_svc" } -ErrorAction SilentlyContinue
if (-not `$gmsaExists) {
    New-ADServiceAccount -Name "gmsa_svc" -DNSHostName "gmsa_svc.`$domainDNS" -PrincipalsAllowedToRetrieveManagedPassword "GMSA-Readers" -Enabled `$true
}

`$gmsaSID    = (Get-ADServiceAccount "gmsa_svc").SID
`$dcObj      = [ADSI]"LDAP://`$domainDN"
`$guidRepl    = [GUID]"1131f6aa-9c07-11d1-f79f-00c04fc2dcd2"
`$guidReplAll = [GUID]"1131f6ad-9c07-11d1-f79f-00c04fc2dcd2"
`$aceRepl    = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(`$gmsaSID, "ExtendedRight", "Allow", `$guidRepl)
`$aceReplAll = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(`$gmsaSID, "ExtendedRight", "Allow", `$guidReplAll)
`$acl = `$dcObj.psbase.ObjectSecurity
`$acl.AddAccessRule(`$aceRepl)
`$acl.AddAccessRule(`$aceReplAll)
`$dcObj.psbase.CommitChanges()

"DONE" | Out-File C:\gmsa_setup_status.txt
"@
$gmsaScript | Out-File -FilePath "C:\setup_gmsa.ps1" -Encoding UTF8
Remove-Item "C:\gmsa_setup_status.txt" -Force -ErrorAction SilentlyContinue

$tomorrow = (Get-Date).AddDays(1).ToString("MM/dd/yyyy")
schtasks /create /f /tn "SetupGMSA" /sc once /sd $tomorrow /st 00:00 /rl highest /ru "$netbios\Administrator" /rp $adminPw /tr "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\setup_gmsa.ps1" 2>&1 | Out-Null
schtasks /run /tn "SetupGMSA" 2>&1 | Out-Null

$elapsed = 0
while ($elapsed -lt 120) {
    Start-Sleep -Seconds 5; $elapsed += 5
    if (Test-Path "C:\gmsa_setup_status.txt") { break }
}
schtasks /delete /tn "SetupGMSA" /f 2>&1 | Out-Null
Remove-Item "C:\setup_gmsa.ps1" -Force -ErrorAction SilentlyContinue

if (Test-Path "C:\gmsa_setup_status.txt") {
    Write-Host "  [KDS] Root key ready"
    Write-Host "  [GMSA] gmsa_svc$ created with DCSync rights"
} else {
    Write-Host "  [WARN] GMSA setup timed out" -ForegroundColor Red
}

$gmsaReadersDN = (Get-ADGroup "GMSA-Readers").DistinguishedName
Set-ADObjectACE -TargetDN $gmsaReadersDN -PrincipalSAM "d.patel" -RightType "WriteOwner"

Write-Host "  [OK] WriteOwner -> GMSA -> DCSync chain ready" -ForegroundColor Green

# ============================================================================
# CHAIN 7: AllExtendedRights -> LAPS -> Lateral Movement
# t.brown -> AllExtendedRights on SVR1$ -> can read LAPS password -> local admin on SVR1
# LAPS schema extension runs via scheduled task (requires Schema Admin context)
# ============================================================================
Write-Host ""
Write-Host "[Chain 7] LAPS / AllExtendedRights (t.brown -> SVR1$)" -ForegroundColor Green

$lapsScript = @"
Import-Module ActiveDirectory
`$schemaPath = (Get-ADRootDSE).schemaNamingContext

`$attr1 = Get-ADObject -SearchBase `$schemaPath -Filter { lDAPDisplayName -eq "ms-Mcs-AdmPwd" } -ErrorAction SilentlyContinue
if (-not `$attr1) {
    New-ADObject -Name "ms-Mcs-AdmPwd" -Type "attributeSchema" -Path `$schemaPath -OtherAttributes @{
        lDAPDisplayName = "ms-Mcs-AdmPwd"; adminDisplayName = "ms-Mcs-AdmPwd"
        attributeID     = "1.2.840.113556.1.8000.2554.50051.45980.28112.18903.35903.6685103.1224907.2.1"
        attributeSyntax = "2.5.5.5"; oMSyntax = 22; isSingleValued = `$true; searchFlags = 904
    }
}

`$attr2 = Get-ADObject -SearchBase `$schemaPath -Filter { lDAPDisplayName -eq "ms-Mcs-AdmPwdExpirationTime" } -ErrorAction SilentlyContinue
if (-not `$attr2) {
    New-ADObject -Name "ms-Mcs-AdmPwdExpirationTime" -Type "attributeSchema" -Path `$schemaPath -OtherAttributes @{
        lDAPDisplayName = "ms-Mcs-AdmPwdExpirationTime"; adminDisplayName = "ms-Mcs-AdmPwdExpirationTime"
        attributeID     = "1.2.840.113556.1.8000.2554.50051.45980.28112.18903.35903.6685103.1224907.2.2"
        attributeSyntax = "2.5.5.16"; oMSyntax = 65; isSingleValued = `$true; searchFlags = 0
    }
}

`$dse = [ADSI]"LDAP://RootDSE"
`$dse.Put("schemaUpdateNow", 1)
`$dse.SetInfo()
Start-Sleep -Seconds 5

`$computerClass = Get-ADObject -SearchBase `$schemaPath -Filter { lDAPDisplayName -eq "computer" } -Properties mayContain
if (`$computerClass) {
    Set-ADObject `$computerClass -Add @{ mayContain = @("ms-Mcs-AdmPwd", "ms-Mcs-AdmPwdExpirationTime") } -ErrorAction SilentlyContinue
    `$dse.Put("schemaUpdateNow", 1)
    `$dse.SetInfo()
    Start-Sleep -Seconds 3
}

`$svr1 = Get-ADComputer "SVR1" -ErrorAction SilentlyContinue
if (`$svr1) {
    Set-ADComputer "SVR1" -Replace @{ "ms-Mcs-AdmPwd" = "L@ps#R4ndom2025!" } -ErrorAction SilentlyContinue
}

"DONE" | Out-File C:\laps_setup_status.txt
"@
$lapsScript | Out-File -FilePath "C:\setup_laps.ps1" -Encoding UTF8
Remove-Item "C:\laps_setup_status.txt" -Force -ErrorAction SilentlyContinue

schtasks /create /f /tn "SetupLAPS" /sc once /sd $tomorrow /st 00:00 /rl highest /ru "$netbios\Administrator" /rp $adminPw /tr "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\setup_laps.ps1" 2>&1 | Out-Null
schtasks /run /tn "SetupLAPS" 2>&1 | Out-Null

$elapsed = 0
while ($elapsed -lt 120) {
    Start-Sleep -Seconds 5; $elapsed += 5
    if (Test-Path "C:\laps_setup_status.txt") { break }
}
schtasks /delete /tn "SetupLAPS" /f 2>&1 | Out-Null
Remove-Item "C:\setup_laps.ps1" -Force -ErrorAction SilentlyContinue

if (Test-Path "C:\laps_setup_status.txt") {
    Write-Host "  [LAPS] Schema extended and SVR1 password set"
} else {
    Write-Host "  [WARN] LAPS setup timed out - SVR1 may not have joined yet (AllExtendedRights still set)" -ForegroundColor Yellow
}

$svr1 = $null
try { $svr1 = Get-ADComputer "SVR1" -ErrorAction Stop } catch { }
if ($svr1) {
    Set-ADObjectACE -TargetDN $svr1.DistinguishedName -PrincipalSAM "t.brown" -RightType "AllExtendedRights"
    Write-Host "  [OK] t.brown: AllExtendedRights on SVR1$" -ForegroundColor Green
} else {
    Write-Host "  [WARN] SVR1 not in AD yet - AllExtendedRights will be set by configure-machine-attacks.ps1" -ForegroundColor Yellow
}

Write-Host "  [OK] AllExtendedRights -> LAPS chain ready" -ForegroundColor Green

# ============================================================================
# ADDITIONAL GROUP MEMBERSHIPS
# ============================================================================
Write-Host ""
Write-Host "[Extra] Populating additional group memberships..." -ForegroundColor Green

$rdpUsers = @("a.johnson", "t.brown", "r.chen", "l.garcia", "d.patel")
foreach ($u in $rdpUsers) {
    Add-ADGroupMember -Identity "Remote Desktop Users" -Members $u -ErrorAction SilentlyContinue
}
Write-Host "  [GROUP] Remote Desktop Users populated"

$vpnUsers = @("t.phillips", "j.campbell", "a.foster", "s.wong", "b.turner")
foreach ($u in $vpnUsers) {
    Add-ADGroupMember -Identity "VPN-Users" -Members $u -ErrorAction SilentlyContinue
}
Write-Host "  [GROUP] VPN-Users populated"

Add-ADGroupMember -Identity "LAPS-Admins" -Members @("b.anderson", "r.chen") -ErrorAction SilentlyContinue
Write-Host "  [GROUP] LAPS-Admins populated"

$fsUsers = @("k.lee", "h.robinson", "g.adams", "n.evans", "f.collins")
foreach ($u in $fsUsers) {
    Add-ADGroupMember -Identity "File-Share-Access" -Members $u -ErrorAction SilentlyContinue
}
Write-Host "  [GROUP] File-Share-Access populated"

# ============================================================================
# ANONYMOUS LDAP BIND (dSHeuristics)
# ============================================================================
Write-Host ""
Write-Host "[Extra] Configuring anonymous LDAP bind..." -ForegroundColor Green

$dircfgDN = "CN=Directory Service,CN=Windows NT,CN=Services,CN=Configuration,$domainDN"
try {
    $dircfg = [ADSI]"LDAP://$dircfgDN"
    $dircfg.put("dSHeuristics", "0000002")
    $dircfg.SetInfo()
    Write-Host "  [ANON] dSHeuristics set - anonymous LDAP queries enabled" -ForegroundColor Yellow
} catch {
    Write-Host "  [WARN] Could not set dSHeuristics: $_" -ForegroundColor Red
}

# ============================================================================
# SUMMARY
# ============================================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Attack Path Configuration Complete" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host " Chain 1: Kerberoasting       svc_sqldb (DA + weak SPN password)" -ForegroundColor White
Write-Host " Chain 2: AS-REP Roast        j.martinez -> r.chen -> Server-Admins -> DA" -ForegroundColor White
Write-Host " Chain 3: GenericAll          a.johnson -> Helpdesk-Operators -> svc_backup" -ForegroundColor White
Write-Host " Chain 4: ForceChangePassword m.wilson -> k.lee -> Project-Phoenix -> EA" -ForegroundColor White
Write-Host " Chain 5: GMSA/DCSync         d.patel -> GMSA-Readers -> gmsa_svc$ -> DC" -ForegroundColor White
Write-Host " Chain 6: Delegation          SVR1 (Unconstrained) | svc_web (Constrained) | ADCS (RBCD)" -ForegroundColor White
Write-Host "          (configured in configure-machine-attacks.ps1 after all VMs join)" -ForegroundColor Gray
Write-Host " Chain 7: LAPS                t.brown -> AllExtendedRights -> SVR1$ LAPS password" -ForegroundColor White
Write-Host ""
Write-Host " ACL types configured: GenericAll, GenericWrite, WriteDACL, WriteOwner" -ForegroundColor Gray
Write-Host "                       ForceChangePassword, Self-Membership, AllExtendedRights" -ForegroundColor Gray
Write-Host "                       DS-Replication-Get-Changes, DS-Replication-Get-Changes-All" -ForegroundColor Gray
