$ErrorActionPreference = "Stop"

# Import Phase Timer Module
Import-Module C:\vagrant\sharedscripts\phase-timer.psm1 -Force

# --- 1. READ VARIABLES ---
Start-PhaseTimer -PhaseName "LOADING CONFIGURATION"
. C:\vagrant\sharedscripts\get-lab-config.ps1
$cfg          = Get-LabConfig
$domainConfig = $cfg.domain
$SccmAccounts = $cfg.sccm.accounts
$SccmAcctPass = $cfg.sccm.accountPassword

# --- 2. SETUP CREDENTIALS ---
$AdminPassRaw = $domainConfig.administratorPassword
$securePassword = ConvertTo-SecureString $AdminPassRaw -AsPlainText -Force
$username = $domainConfig.netbiosName + "\Administrator"
$domainAdminCredentials = New-Object System.Management.Automation.PSCredential($username, $securePassword)

$DomainName = $domainConfig.fqdn
$DomainDN = $domainConfig.dn
$SchemaMaster = "$($domainConfig.dcName).$($domainConfig.fqdn)"  # e.g. DVAD-DC.dvad.lab

Write-Host "Configuration Loaded:" -ForegroundColor Cyan
Write-Host " - Domain: $DomainName"
Write-Host " - Admin: $username"
Write-Host " - Target DC: $SchemaMaster"

Start-Transcript -Path "C:\SCCM_Install_Log.txt" -Force
Stop-PhaseTimer -Status Success

# --- 3. PREPARE LOCAL TOOLS ---
Start-PhaseTimer -PhaseName "PREPARING RSAT TOOLS"
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Host "Installing RSAT-AD-PowerShell..."
    Install-WindowsFeature -Name "RSAT-AD-PowerShell" 
}
Import-Module ActiveDirectory -Force
Stop-PhaseTimer -Status Success

# --- 4. PREPARE REMOTE SCRIPT BLOCK (Runs on DC) ---
$remoteScriptBlock = {
    param (
        [string]$SCCMComputerName,
        [string]$Password,
        [string]$DomainDN,
        [string]$DomainFQDN,
        [object]$Accounts
    )

    Import-Module ActiveDirectory

    # [TASK A] CREATE OU & USERS
    $OUName = "SCCMObjects"
    $OUPath = "OU=$OUName,$DomainDN"

    if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$OUName'")) {
        New-ADOrganizationalUnit -Name $OUName -Path $DomainDN -ProtectedFromAccidentalDeletion $false
        Write-Host "Created OU: $OUName"
    }

    # Helper function for Users
    function New-SccmUser ($Name, $Disp) {
        if (-not (Get-ADUser -Filter "SamAccountName -eq '$Name'")) {
            New-ADUser -SamAccountName $Name -Name $Disp -DisplayName $Disp -Path $OUPath `
                -UserPrincipalName "$Name@$DomainFQDN" `
                -AccountPassword (ConvertTo-SecureString $Password -AsPlainText -Force) `
                -Enabled $true -PasswordNeverExpires $true
            Write-Host "Created User: $Name"
        }
    }

    New-SccmUser $Accounts.admin "SCCM Administrator"
    New-SccmUser $Accounts.sqlAgent "SQL Server Agent"
    New-SccmUser $Accounts.networkAccess "SCCM Network Access Account"
    New-SccmUser $Accounts.clientPush "SCCM Client Push Install Account"
    New-SccmUser $Accounts.domainJoin "SCCM OSD Domain Join Account"

    # Create Group
    if (-not (Get-ADGroup -Filter "Name -eq 'SCCM Admins Group'")) {
        New-ADGroup -Name "SCCM Admins Group" -GroupScope Global -Path $OUPath -Description "SCCM Admins"
        Write-Host "Created Group: SCCM Admins Group"
    }
    Add-ADGroupMember -Identity "SCCM Admins Group" -Members $Accounts.admin -ErrorAction SilentlyContinue

    # [TASK B] SYSTEM MANAGEMENT CONTAINER & PERMISSIONS
    $SystemDN = "CN=System,$DomainDN"
    $ContainerDN = "CN=System Management,$SystemDN"

    # 1. Create Container if missing
    if (-not (Get-ADObject -Filter "Name -eq 'System Management'" -SearchBase $SystemDN)) {
        New-ADObject -Name "System Management" -Type Container -Path $SystemDN
        Write-Host " [OK] Created 'System Management' container." -ForegroundColor Green
    }

    # 2. Get the REAL SCCM Computer Object
    try {
        $SCCMComp = Get-ADComputer -Identity $SCCMComputerName
        $SidStr = $SCCMComp.SID.Value
        Write-Host " [INFO] Found SCCM Computer SID: $SidStr"
    }
    catch {
        Write-Error " [FAIL] Could not find computer account for '$SCCMComputerName' in AD!"
        return
    }

    # 3. Grant Permissions using Strictly Typed ACLs (Fixes "Ambiguous Overload")
    try {
        $Acl = Get-Acl -Path "AD:\$ContainerDN"
        
        # We must define these variables with explicit types to stop PowerShell from guessing
        $Identity = New-Object System.Security.Principal.SecurityIdentifier($SidStr)
        $AdRights = [System.DirectoryServices.ActiveDirectoryRights]::GenericAll
        $AccessType = [System.Security.AccessControl.AccessControlType]::Allow
        $Inheritance = [System.DirectoryServices.ActiveDirectorySecurityInheritance]::All

        # Create the Rule using the strictly typed variables
        $Ar = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($Identity, $AdRights, $AccessType, $Inheritance)
        
        $already = $Acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]) | Where-Object {
            $_.IdentityReference.Value -eq $SidStr -and
            $_.ActiveDirectoryRights   -eq $AdRights -and
            $_.AccessControlType       -eq $AccessType -and
            $_.ObjectType              -eq ([guid]::Empty)
        }
        if ($already) {
            Write-Host " [SKIP] $($SCCMComp.Name) already has Full Control on System Management." -ForegroundColor Green
        }
        else {
            $Acl.AddAccessRule($Ar)
            Set-Acl -Path "AD:\$ContainerDN" -AclObject $Acl
            Write-Host " [SUCCESS] Granted Full Control to $($SCCMComp.Name) on System Management." -ForegroundColor Green
        }
    }
    catch {
        Write-Error " [FAIL] Failed to set permissions on System Management container: $_"
    }
    
    # [TASK C] EXTEND SCHEMA (No Copying Needed)
    # Use the existing path on the DC
    $ExistingExe = "C:\vagrant\sharedscripts\services\SCCM\extendSchema\extadsch.exe"
    $LogFile = "C:\ExtADSch.log"
    
    Write-Host "--- Extending Schema (On DC) ---"
    
    if (Test-Path $ExistingExe) {
        # Check idempotency
        $SchemaPath = (Get-ADRootDSE).SchemaNamingContext
        if (Get-ADObject -Filter "name -eq 'MS-SMS-Management-Point'" -SearchBase $SchemaPath -ErrorAction SilentlyContinue) {
            Write-Host "SUCCESS: Schema is ALREADY extended. Skipping." -ForegroundColor Green
        }
        else {
            Write-Host "Found tool at $ExistingExe. Running..."
            Start-Process -FilePath $ExistingExe -Wait -NoNewWindow
             
            # Verify
            if (Test-Path $LogFile) {
                $LogContent = Get-Content $LogFile -Raw
                if ($LogContent -match "Successfully extended the Active Directory schema") {
                    Write-Host "SUCCESS: Schema extended successfully." -ForegroundColor Green
                }
                elseif ($LogContent -match "Active Directory schema is already up to date") {
                    Write-Host "SUCCESS: Schema was up to date." -ForegroundColor Green
                }
                else {
                    Write-Error "FAILURE: Tool ran but failed. Content:`n$LogContent"
                }
            }
            else {
                Write-Error "FAILURE: Log file not found at $LogFile"
            }
        }
    }
    else {
        Write-Error "FAILURE: extadsch.exe not found at $ExistingExe on the Domain Controller!"
    }
}

# --- 5. EXECUTE REMOTE BLOCK ---
Start-PhaseTimer -PhaseName "AD PREPARATION & SCHEMA EXTENSION"
Write-Host "Executing AD Prep & Schema Extension on DC..." -ForegroundColor Cyan
try {
    Invoke-Command -ComputerName $SchemaMaster -Credential $domainAdminCredentials -ScriptBlock $remoteScriptBlock -ArgumentList $env:COMPUTERNAME, $SccmAcctPass, $DomainDN, $DomainName, $SccmAccounts
    Stop-PhaseTimer -Status Success
}
catch {
    Stop-PhaseTimer -Status Failed
    Write-Error "Failed to execute remote script on DC: $_"
}

# --- 6. LOCAL ADMINS (Run Locally on SCCM) ---
Start-PhaseTimer -PhaseName "CONFIGURING LOCAL ADMINS"
try {
    $LocalGroup = [ADSI]"WinNT://./Administrators,group"
    $DomainNetBIOS = $domainConfig.netbiosName
    
    try {
        $LocalGroup.Add("WinNT://$DomainNetBIOS/$($SccmAccounts.admin),user")
        Write-Host "Added $($SccmAccounts.admin) to Local Administrators."
    }
    catch { Write-Host "$($SccmAccounts.admin) likely already a local admin." }
    Stop-PhaseTimer -Status Success
}
catch {
    Stop-PhaseTimer -Status Failed
    Write-Error "Failed to update Local Admins: $_"
}

# --- 7. ENABLE SERVICES ---
Start-PhaseTimer -PhaseName "ENABLING REQUIRED SERVICES"
Write-Host "--- Enabling Services ---"
Set-Service -Name wuauserv -StartupType Automatic
Set-Service -Name bits -StartupType Automatic
Set-Service -Name cryptsvc -StartupType Automatic
Set-Service -Name trustedinstaller -StartupType Automatic
Stop-PhaseTimer -Status Success

Show-InstallationSummary
Stop-Transcript