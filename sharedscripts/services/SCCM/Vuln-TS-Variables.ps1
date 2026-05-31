# ==============================================================================
# Script: vulnerableTS.ps1 (Merged)
# Purpose: Creates TWO Vulnerable Task Sequences for Credential Theft Scenarios
#   1. "Vulnerable Task Sequence" (Anonymous/Hidden Variable Leak)
#   2. "Pilot Upgrade TS" (Authenticated Domain Join Credential Leak)
#   3. "Windows 11 Pilot Group" Collection with "AWS_Migration_Secret" Variable
# ==============================================================================

# --- CONFIGURATION ---
$SiteCode = "PS1"
$SiteServer = "SCCM.silent.run"
$BootImageName = "Boot Image (x64)"  

# Scenario 1 Config (Anonymous TS)
$TSName_Anon = "Vulnerable Task Sequence"
$SecretName_Anon = "EnableDebugMode"
$SecretValue_Anon = "SuperSecretPassword123!" 
$Collection_Anon = "All Systems"

# Scenario 2 Config (Authenticated TS)
$TSName_Auth = "Pilot Upgrade TS"
$Collection_Auth = "Windows 11 Pilot Group"
$LimitingColl_Auth = "All Systems"
$NamingPattern_Auth = "PILOT-%"
$DomainName = "silent.run"
$JoinAccount = "SILENT\sccm_dja"
$JoinPassword = "P@ssw0rd"

# Scenario 3 Config (Collection Variable)
$CollVarName = "AWS_Migration_Secret"
$CollVarValue = "AKIA-SERVER-MIGRATION-KEY-999"

# ==============================================================================
# INITIALIZATION: LOAD MODULE & CONNECT TO SITE
# ==============================================================================
Write-Host "--- INITIALIZING SCCM MODULE ---" -ForegroundColor Cyan
try {
    # 1. Locate ConfigurationManager.psd1 via Registry
    $RegKey = "HKLM:\SOFTWARE\Microsoft\ConfigMgr10\Setup"
    $ConsolePath = $null
    
    if (Test-Path $RegKey) {
        $InstallDir = (Get-ItemProperty -Path $RegKey -Name "UI Installation Directory" -ErrorAction SilentlyContinue)."UI Installation Directory"
        if ($InstallDir) {
            $ConsolePath = Join-Path $InstallDir "bin\ConfigurationManager.psd1"
        }
    }

    # 2. Fallback
    if (-not $ConsolePath -or -not (Test-Path $ConsolePath)) {
        $PossiblePaths = @(
            "$($Env:SMS_ADMIN_UI_PATH)\..\ConfigurationManager.psd1",
            "C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1"
        )
        $ConsolePath = $PossiblePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    }

    # 3. Load Module
    if ($ConsolePath -and (Test-Path $ConsolePath)) {
        Import-Module $ConsolePath -ErrorAction Stop
    }
    else {
        Throw "Could not locate ConfigurationManager.psd1 in any standard location."
    }

    # 4. Connect to Site
    if ((Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue) -eq $null) {
        New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer -ErrorAction Stop | Out-Null
    }
    Set-Location "$($SiteCode):"
    Write-Host " [OK] Connected to Site $SiteCode" -ForegroundColor Green

}
catch {
    Write-Error "Failed to load SCCM Module: $_"
    exit 1
}

# ==============================================================================
# PART 1: ANONYMOUS TASK SEQUENCE (Hidden Variable Leak)
# ==============================================================================
Write-Host "`n=== PART 1: ANONYMOUS TASK SEQUENCE ===" -ForegroundColor Yellow

# 1. Find Boot Image
$BootImage = Get-CMBootImage -Name $BootImageName | Select-Object -First 1
if (-not $BootImage) { Write-Error "Boot Image '$BootImageName' not found."; exit 1 }
$BootImageId = $BootImage.PackageID

# 2. Create TS
try {
    Remove-CMTaskSequence -Name $TSName_Anon -Force -ErrorAction SilentlyContinue
    $TS_Anon = New-CMTaskSequence -Name $TSName_Anon -CustomTaskSequence -BootImagePackageId $BootImageId -Description "Misconfigured TS with Secret Variable"
    
    # 3. Add Variable Step
    $StepVar = New-CMTSStepSetVariable -Name "Set Admin Secret" -TaskSequenceVariable $SecretName_Anon -TaskSequenceVariableValue $SecretValue_Anon
    Add-CMTaskSequenceStep -TaskSequenceName $TSName_Anon -Step $StepVar
    
    # 4. Deploy to All Systems
    $CollObj = Get-CMCollection -Name $Collection_Anon
    if (-not (Get-CMTaskSequenceDeployment -TaskSequencePackageId $TS_Anon.PackageID -Fast)) {
        New-CMTaskSequenceDeployment -TaskSequencePackageId $TS_Anon.PackageID -CollectionId $CollObj.CollectionID -DeployPurpose Available -AvailableDateTime (Get-Date) | Out-Null
        Write-Host " [OK] '$TSName_Anon' deployed to '$Collection_Anon'." -ForegroundColor Green
    }
}
catch {
    Write-Error "Part 1 Failed: $_"
}

# ==============================================================================
# PART 2: AUTHENTICATED PILOT TS (Domain Join Credential Leak)
# ==============================================================================
Write-Host "`n=== PART 2: AUTHENTICATED PILOT TASK SEQUENCE ===" -ForegroundColor Yellow

try {
    # 1. Create Collection
    if (-not (Get-CMCollection -Name $Collection_Auth)) {
        New-CMDeviceCollection -Name $Collection_Auth -LimitingCollectionName $LimitingColl_Auth | Out-Null
        Set-CMCollection -Name $Collection_Auth -RefreshType Continuous | Out-Null
        $Query = "select * from SMS_R_System where Name like '$NamingPattern_Auth'"
        Add-CMDeviceCollectionQueryMembershipRule -CollectionName $Collection_Auth -RuleName "Auto-Add Pilots" -QueryExpression $Query | Out-Null
        Write-Host " [OK] Collection '$Collection_Auth' created." -ForegroundColor Green
    }

    # 2. Create TS
    Remove-CMTaskSequence -Name $TSName_Auth -Force -ErrorAction SilentlyContinue
    $TS_Auth = New-CMTaskSequence -Name $TSName_Auth -CustomTaskSequence -BootImagePackageId $BootImageId

    # 3. Add Domain Join Step (The Vulnerability)
    $SecurePassword = ConvertTo-SecureString -String $JoinPassword -AsPlainText -Force
    $JoinStep = New-CMTSStepJoinDomainWorkgroup -Name "Join Domain (Vulnerable)" -DomainName $DomainName -OU "LDAP://CN=Computers,DC=silent,DC=run" -UserName $JoinAccount -UserPassword $SecurePassword
    Add-CMTaskSequenceStep -TaskSequenceName $TSName_Auth -Step $JoinStep

    # 4. Deploy
    New-CMTaskSequenceDeployment -TaskSequencePackageId $TS_Auth.PackageID -CollectionName $Collection_Auth -DeployPurpose Available -AvailableDateTime (Get-Date) -MakeAvailableTo ClientsMediaAndPxe | Out-Null
    Write-Host " [OK] '$TSName_Auth' deployed to '$Collection_Auth'." -ForegroundColor Green

}
catch {
    Write-Error "Part 2 Failed: $_"
}

# ==============================================================================
# PART 3: COLLECTION VARIABLES (Scenario C)
# ==============================================================================
Write-Host "`n=== PART 3: COLLECTION VARIABLES ===" -ForegroundColor Yellow

try {
    $CurrentVar = Get-CMDeviceCollectionVariable -CollectionName $Collection_Auth -VariableName $CollVarName -ErrorAction SilentlyContinue

    if ($CurrentVar) {
        Set-CMDeviceCollectionVariable -CollectionName $Collection_Auth -VariableName $CollVarName -NewVariableValue $CollVarValue -IsMask $true | Out-Null
        Write-Host " [OK] Variable updated." -ForegroundColor Green
    }
    else {
        New-CMDeviceCollectionVariable -CollectionName $Collection_Auth -VariableName $CollVarName -Value $CollVarValue -IsMask $true | Out-Null
        Write-Host " [OK] Variable created." -ForegroundColor Green
    }
}
catch {
    Write-Error "Part 3 Failed: $_"
}

Write-Host "`n[COMPLETE] Vulnerable TS Configuration Finished." -ForegroundColor Magenta