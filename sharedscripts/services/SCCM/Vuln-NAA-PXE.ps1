param(
    [switch]$NAAExecutionMode
)

# ==============================================================================
# Script: CRED1.ps1 (Merged)
# Purpose: Automates "Vulnerable PXE" Config, IIS Fixes, Boundary Setup, AND NAA
# ==============================================================================
#
# This script performs the following critical actions for the lab setup:
#   1. Connects to the SCCM Site (Site Code: PS1)
#   2. Configures Site Insecurity (Disables PKI/HTTPS requirements)
#   3. Fixes IIS Permissions for Management Point (MP) and Distribution Point (DP)
#   4. Creates/Configures "Lab Subnet" Boundary and "Lab Boundary Group"
#   5. Distributes Boot Images (x86/x64) and Enables PXE
#   6. Configures PXE Responder Service
#   7. Deploys a "PXE Attack" Task Sequence
#   8. [NEW] Configures NAA (Network Access Account) via Scheduled Task
#   9. [NEW] Combined Verification Phase
#
# ==============================================================================

# --- IMPORT PHASE TIMER MODULE ---
$TimerModule = "$PSScriptRoot\PhaseTimer.psm1"
if (Test-Path $TimerModule) { Import-Module $TimerModule -Force -ErrorAction SilentlyContinue } 

# --- CONFIGURATION VARIABLES ---
$SiteCode = "PS1"
$SiteServer = "SCCM.silent.run"
$BoundaryIP = "10.10.10.0"
$BoundaryName = "Lab Subnet"
$Group = "Lab Boundary Group"   
$NAA_User = "SILENT\sccm_naa"
$NAA_Pass = "P@ssw0rd"
$TargetAdminUser = "SILENT\Administrator"
$TargetAdminPass = "P@ssw0rd"

# ==============================================================================
# NAA EXECUTION MODE (Called via Scheduled Task as SILENT\Administrator)
# ==============================================================================
if ($NAAExecutionMode) {
    Start-Transcript -Path "C:\CRED1_NAA_Exec_Log.txt" -Force
    Write-Host "--- NAA SUB-PROCESS STARTED ---" -ForegroundColor Cyan
    
    # 1. Load Module (with fallback paths)
    $ConsolePath = $null
    $RegKey = "HKLM:\SOFTWARE\Microsoft\ConfigMgr10\Setup"
    
    if (Test-Path $RegKey) {
        $InstallDir = (Get-ItemProperty -Path $RegKey -Name "UI Installation Directory" -ErrorAction SilentlyContinue)."UI Installation Directory"
        if ($InstallDir) {
            $ConsolePath = Join-Path $InstallDir "bin\ConfigurationManager.psd1"
        }
    }
    
    # Fallback: Check Standard Paths if registry lookup fails
    if (-not $ConsolePath -or -not (Test-Path $ConsolePath)) {
        $PossiblePaths = @(
            "$($Env:SMS_ADMIN_UI_PATH)\..\ConfigurationManager.psd1",
            "C:\Program Files (x86)\Microsoft Endpoint Manager\AdminConsole\bin\ConfigurationManager.psd1",
            "C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1",
            "C:\Program Files\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1"
        )
        $ConsolePath = $PossiblePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    
    if ($ConsolePath -and (Test-Path $ConsolePath)) {
        Write-Host " [INFO] Loading module from: $ConsolePath" -ForegroundColor Gray
        Import-Module $ConsolePath -ErrorAction Stop
    }
    else {
        Write-Error "Could not locate ConfigurationManager.psd1 in any standard location."
        Stop-Transcript
        exit 1
    }
    
    # Verify module loaded correctly
    if (-not (Get-Module -Name ConfigurationManager)) {
        Write-Error "ConfigurationManager module failed to load."
        Stop-Transcript
        exit 1
    }
    
    # 2. Connect to Site
    if ($null -eq (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer -ErrorAction Stop | Out-Null
    }
    Set-Location "$($SiteCode):"

    # 3. Configure NAA (WMI)
    try {
        # Ensure Account Exists
        if (-not (Get-CMAccount -Name $NAA_User -ErrorAction SilentlyContinue)) {
            $SecurePwd = ConvertTo-SecureString $NAA_Pass -AsPlainText -Force
            New-CMAccount -Name $NAA_User -Password $SecurePwd -SiteCode $SiteCode -ErrorAction Stop | Out-Null
            Write-Host " [OK] CM Account created." -ForegroundColor Green
        }
        
        # Configure WMI Component
        $Namespace = "root\sms\site_$SiteCode"
        $Component = Get-WmiObject -Namespace $Namespace -Class SMS_SCI_ClientComp -Filter "ItemName = 'Software Distribution'"
        $PropsList = $Component.PropLists
        
        $Existing = $PropsList | Where-Object { $_.PropertyListName -eq "Network Access User Names" }
        
        if ($Existing) {
            $Existing.Values = @($NAA_User)
            Write-Host " [OK] Updated existing NAA." -ForegroundColor Green
        }
        else {
            $EmbeddedClass = [WmiClass]"\\localhost\$Namespace`:SMS_EmbeddedPropertyList"
            $NewNAA = $EmbeddedClass.CreateInstance()
            $NewNAA.PropertyListName = "Network Access User Names"
            $NewNAA.Values = @($NAA_User)
            $PropsList += $NewNAA
            Write-Host " [OK] Created new NAA property." -ForegroundColor Green
        }
        
        $Component.PropLists = $PropsList
        $Component.Put() | Out-Null
        Write-Host " [SUCCESS] NAA Configuration Applied." -ForegroundColor Green
    }
    catch {
        Write-Error "NAA Config Failed: $_"
        exit 1
    }

    Stop-Transcript
    exit 0
}

# ==============================================================================
# MAIN SCRIPT EXECUTION
# ==============================================================================

# INITIALIZATION: LOAD MODULE & CONNECT TO SITE
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

    # 2. Fallback: Check Standard Paths if registry lookup fails
    if (-not $ConsolePath -or -not (Test-Path $ConsolePath)) {
        $PossiblePaths = @(
            "$($Env:SMS_ADMIN_UI_PATH)\..\ConfigurationManager.psd1",
            "C:\Program Files (x86)\Microsoft Endpoint Manager\AdminConsole\bin\ConfigurationManager.psd1",
            "C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1",
            "C:\Program Files\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1"
        )
        $ConsolePath = $PossiblePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    }

    # 3. Load the Module
    if ($ConsolePath -and (Test-Path $ConsolePath)) {
        Write-Host " [INFO] Found Module at: $ConsolePath" -ForegroundColor Gray
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
# PHASE 1: SITE INSECURITY CONFIGURATION
# ==============================================================================
Start-PhaseTimer -PhaseName "CONFIGURING SITE INSECURITY"
try {
    $SiteObj = Get-CMSite -SiteCode $SiteCode
    if (-not $SiteObj) { Throw "Site '$SiteCode' not found." }
    
    # Disable PKI Client Certificate Requirement (Allow HTTP)
    Set-CMSite -InputObject $SiteObj -UsePkiClientCertificate $false -ErrorAction Stop
    
    # Disable Client Certificate Revocation Checking (CRL Check)
    if (Get-Command Set-CMClientCertificateRevocationChecking -ErrorAction SilentlyContinue) {
        Set-CMClientCertificateRevocationChecking -CheckRevocation $false -ErrorAction SilentlyContinue
    }
    
    Write-Host " [OK] Site Insecurity Configured." -ForegroundColor Green
    Stop-PhaseTimer -Status Success
}
catch {
    Stop-PhaseTimer -Status Failed
    Write-Error "Phase 1 Failed: $_"
    exit 1
}

# ==============================================================================
# PHASE 2: IIS PERMISSIONS FIX (MP/DP ANONYMOUS ACCESS)
# ==============================================================================
Start-PhaseTimer -PhaseName "POST-MECM IIS MP FIX"
try {
    Import-Module WebAdministration

    # Unlock IIS configuration sections at server level using appcmd
    # This fixes: "This configuration section cannot be used at this path" errors
    Write-Host " [INFO] Unlocking IIS authentication sections..." -ForegroundColor Gray
    $appcmd = "$env:SystemRoot\System32\inetsrv\appcmd.exe"
    if (Test-Path $appcmd) {
        & $appcmd unlock config -section:system.webServer/security/authentication/anonymousAuthentication /commit:apphost 2>$null
        & $appcmd unlock config -section:system.webServer/security/authentication/windowsAuthentication /commit:apphost 2>$null
        & $appcmd unlock config -section:system.webServer/security/access /commit:apphost 2>$null
        Write-Host " [OK] IIS sections unlocked." -ForegroundColor Green
    }
    else {
        Write-Warning "appcmd.exe not found - IIS sections may remain locked"
    }

    # 1. FIX ROOT MP (SMS_MP) - Enable both Windows Auth & Anonymous
    $RootPath = "IIS:\Sites\Default Web Site\SMS_MP"
    if (Test-Path $RootPath) {
        Write-Host "Fixing MP Root: $RootPath"
        Set-WebConfigurationProperty -Filter "/system.webServer/security/access" -PSPath $RootPath -Name "sslFlags" -Value "None" -ErrorAction SilentlyContinue
        Set-WebConfigurationProperty -Filter "/system.webServer/security/authentication/anonymousAuthentication" -PSPath $RootPath -Name "enabled" -Value $true -ErrorAction SilentlyContinue
        Set-WebConfigurationProperty -Filter "/system.webServer/security/authentication/windowsAuthentication" -PSPath $RootPath -Name "enabled" -Value $true -ErrorAction SilentlyContinue
    }

    # 2. FIX KEY EXCHANGE (.sms_aut) - MUST BE ANONYMOUS ONLY
    $AutPath = "IIS:\Sites\Default Web Site\SMS_MP\.sms_aut"
    if (Test-Path $AutPath) {
        Write-Host "Fixing Key Exchange: $AutPath"
        Set-WebConfigurationProperty -Filter "/system.webServer/security/access" -PSPath $AutPath -Name "sslFlags" -Value "None" -ErrorAction SilentlyContinue
        Set-WebConfigurationProperty -Filter "/system.webServer/security/authentication/anonymousAuthentication" -PSPath $AutPath -Name "enabled" -Value $true -ErrorAction SilentlyContinue
        Set-WebConfigurationProperty -Filter "/system.webServer/security/authentication/windowsAuthentication" -PSPath $AutPath -Name "enabled" -Value $false -ErrorAction SilentlyContinue
    }

    # 3. FIX DP (SMS_DP) - Enable Both
    $DPPath = "IIS:\Sites\Default Web Site\SMS_DP"
    if (Test-Path $DPPath) {
        Write-Host "Fixing DP: $DPPath"
        Set-WebConfigurationProperty -Filter "/system.webServer/security/access" -PSPath $DPPath -Name "sslFlags" -Value "None" -ErrorAction SilentlyContinue
        Set-WebConfigurationProperty -Filter "/system.webServer/security/authentication/anonymousAuthentication" -PSPath $DPPath -Name "enabled" -Value $true -ErrorAction SilentlyContinue
        Set-WebConfigurationProperty -Filter "/system.webServer/security/authentication/windowsAuthentication" -PSPath $DPPath -Name "enabled" -Value $true -ErrorAction SilentlyContinue
    }

    # 4. RESTART IIS SERVICES
    Restart-WebAppPool -Name "DefaultAppPool" -ErrorAction SilentlyContinue
    Restart-WebAppPool -Name "CMSite" -ErrorAction SilentlyContinue
    iisreset /restart /timeout:30
    
    Write-Host " [OK] MP IIS bindings fixed (Split Logic)." -ForegroundColor Green
    Stop-PhaseTimer -Status Success
}
catch {
    Stop-PhaseTimer -Status Warning
    Write-Warning "IIS Fix Failed: $_"
}

# ==============================================================================
# PHASE 3: BOUNDARIES & BOUNDARY GROUP
# ==============================================================================
Start-PhaseTimer -PhaseName "BOUNDARIES & ASSIGNMENT"
try {
    # 1. Create IP Subnet Boundary
    $Boundary = Get-CMBoundary -Name $BoundaryName -ErrorAction SilentlyContinue
    if (-not $Boundary) {
        $Boundary = New-CMBoundary -Name $BoundaryName -Type IPSubnet -Value $BoundaryIP -ErrorAction Stop
        Write-Host " [OK] Boundary 'Lab Subnet' created ($BoundaryIP)." -ForegroundColor Green
    }
    else {
        Write-Host " [INFO] Boundary 'Lab Subnet' already exists." -ForegroundColor Gray
    }

    # 2. Create Boundary Group
    $BoundaryGroup = Get-CMBoundaryGroup -Name $Group -ErrorAction SilentlyContinue
    if (-not $BoundaryGroup) {
        $BoundaryGroup = New-CMBoundaryGroup -Name $Group -ErrorAction Stop
        Write-Host " [OK] Boundary Group 'Lab Boundary Group' created." -ForegroundColor Green
    }
    else {
        Write-Host " [INFO] Boundary Group 'Lab Boundary Group' already exists." -ForegroundColor Gray
    }

    # 3. Link Boundary to Group
    Add-CMBoundaryToGroup -BoundaryName $BoundaryName -BoundaryGroupName $Group -ErrorAction SilentlyContinue
    Write-Host " [OK] Boundary 'Lab Subnet' linked to 'Lab Boundary Group'." -ForegroundColor Green

    # 4. Assign Site & DP to Boundary Group
    $SiteSystemObj = Get-CMSiteSystemServer -SiteCode $SiteCode | Select-Object -First 1
    if (-not $SiteSystemObj) {
        Throw "Get-CMSiteSystemServer returned no objects for site '$SiteCode'."
    }

    Write-Host " [INFO] Using Site System object: $($SiteSystemObj.NetworkOSPath)" -ForegroundColor Gray

    Set-CMBoundaryGroup `
        -InputObject $BoundaryGroup `
        -AddSiteSystemServer $SiteSystemObj `
        -DefaultSiteCode $SiteCode `
        -ErrorAction Stop

    Write-Host " [OK] Boundary Group assigned to Site '$SiteCode' and DP." -ForegroundColor Green
    Stop-PhaseTimer -Status Success

}
catch {
    Stop-PhaseTimer -Status Failed
    Write-Error "Phase 3 Failed: $_"
    exit 1
}

# ==============================================================================
# PHASE 4: BOOT IMAGES
# ==============================================================================
Start-PhaseTimer -PhaseName "BOOT IMAGE CONTENT"
try {
    # Get Boot Images
    $BootImgX86 = Get-CMBootImage | Where-Object { $_.Name -like "*x86*" } | Select-Object -First 1
    $BootImgX64 = Get-CMBootImage | Where-Object { $_.Name -like "*x64*" } | Select-Object -First 1

    if (-not $BootImgX86) { Throw "No x86 Boot Image found." }
    if (-not $BootImgX64) { Throw "No x64 Boot Image found." }

    # Function to handle distribution logic
    function Enable-And-DistributeBootImage {
        param(
            [Parameter(Mandatory = $true)] $BootImg,
            [Parameter(Mandatory = $true)] [bool]$EnablePxe
        )

        Write-Host " [INFO] Processing boot image '$($BootImg.Name)'..." -ForegroundColor Gray

        # Detect Legacy WinPE (Skip PXE flag if legacy)
        $isLegacy = $false
        if ($BootImg.PSObject.Properties.Name -contains 'ImageOSVersion') {
            $osVer = $BootImg.ImageOSVersion
            if ($osVer -like "6.0.*" -or $osVer -like "6.1.*") { $isLegacy = $true }
        }

        # Enable PXE support on the image itself
        if ($EnablePxe -and -not $isLegacy) {
            Set-CMBootImage -Id $BootImg.PackageID -DeployFromPxeDistributionPoint $true -ErrorAction Stop
            Write-Host " [OK] Set 'DeployFromPxeDistributionPoint' to UPDATE." -ForegroundColor Green
        }

        # Distribute to DP
        try {
            Start-CMContentDistribution -BootImageId $BootImg.PackageID -DistributionPointName $SiteServer -ErrorAction Stop
            Write-Host " [OK] Distribution started." -ForegroundColor Green
        }
        catch {
            if ($_.Exception.Message -like "*already been distributed*") {
                Write-Host " [INFO] Already distributed." -ForegroundColor Gray
            }
            else { throw }
        }
    }

    # Process Images
    Enable-And-DistributeBootImage -BootImg $BootImgX86 -EnablePxe:$false
    Enable-And-DistributeBootImage -BootImg $BootImgX64 -EnablePxe:$true

    Write-Host " [INFO] Waiting 1 minute for boot image staging..." -ForegroundColor Yellow
    Start-Sleep -Seconds 60

    Stop-PhaseTimer -Status Success

}
catch {
    Stop-PhaseTimer -Status Failed
    Write-Error "Phase 4 Failed: $_"
}

# ==============================================================================
# PHASE 5: ENABLE PXE SERVICE & DEPLOYMENT
# ==============================================================================
Start-PhaseTimer -PhaseName "ENABLE PXE & Deploy Task Sequence"
try {
    # 1. Enable PXE on Distribution Point
    Set-CMDistributionPoint -SiteCode $SiteCode -SiteSystemServerName $SiteServer `
        -EnablePxe $true `
        -AllowPxeResponse $true `
        -EnableUnknownComputerSupport $true `
        -EnableNonWdsPxe $true `
        -ErrorAction Stop

    Write-Host " [OK] PXE Settings Applied." -ForegroundColor Green
    Write-Host " [INFO] Waiting for PXE provider to initialize..." -ForegroundColor Yellow

    # 2. Wait for Service
    $MaxRetries = 24
    $Found = $false
    for ($i = 0; $i -lt $MaxRetries; $i++) {
        $Svc = Get-Service -Name "SccmPxe" -ComputerName $SiteServer -ErrorAction SilentlyContinue
        if ($Svc -and $Svc.Status -eq "Running") {
            $Found = $true
            break
        }
        Write-Host -NoNewline "."
        Start-Sleep -Seconds 5
    }

    if ($Found) {
        Write-Host "`n [OK] ConfigMgr PXE Responder Service is RUNNING." -ForegroundColor Green
    }
    else {
        Write-Warning "`n [WARN] PXE provider still initializing. Check SMSPXE.log."
    }

    # 3. Create Task Sequence
    $BootImg = Get-CMBootImage | Where-Object { $_.Name -like "*x64*" } | Select-Object -First 1
    $TSName = "PXE Attack"

    $TS = Get-CMTaskSequence -Name $TSName -Fast -ErrorAction SilentlyContinue
    if (-not $TS) {
        $TS = New-CMTaskSequence -CustomTaskSequence -Name $TSName -ErrorAction Stop
        Write-Host " [OK] Task Sequence '$TSName' created." -ForegroundColor Green
    }
    else {
        Write-Host " [INFO] Task Sequence '$TSName' already exists." -ForegroundColor Gray
    }

    # Bind Boot Image
    $TS.BootImageID = $BootImg.PackageID
    $TS.Put() | Out-Null
    $TS = Get-CMTaskSequence -Name $TSName -Fast -ErrorAction Stop # Refresh object

    # 4. Deploy Task Sequence to "All Unknown Computers"
    $Coll = Get-CMCollection -Name "All Unknown Computers" -ErrorAction SilentlyContinue
    if (-not $Coll) { Throw "Collection 'All Unknown Computers' not found." }

    $ExistingDep = Get-CMTaskSequenceDeployment -TaskSequenceName $TSName -Fast -ErrorAction SilentlyContinue
    if (-not $ExistingDep) {
        New-CMTaskSequenceDeployment `
            -TaskSequenceId $TS.PackageID `
            -CollectionId $Coll.CollectionID `
            -DeployPurpose Available `
            -MakeAvailableTo MediaAndPxe `
            -AvailableDateTime (Get-Date).AddDays(-1) `
            -ErrorAction Stop | Out-Null
        Write-Host " [OK] Deployed to '$($Coll.Name)'." -ForegroundColor Green
    }

    # 5. Flush Policies (Fixes 'No Deployment' Cache)
    Write-Host "`n [ACTION] Flushing Policies & Restarting Services..." -ForegroundColor Yellow
    Invoke-CMCollectionUpdate -Name "All Unknown Computers" -ErrorAction SilentlyContinue
    
    Start-Sleep -Seconds 20 
    Restart-Service "SccmPxe" -Force -ErrorAction SilentlyContinue
    Write-Host " [OK] PXE Service Restarted (Cache Cleared)." -ForegroundColor Green

    Stop-PhaseTimer -Status Success

}
catch {
    Stop-PhaseTimer -Status Failed
    Write-Error "Phase 5 Failed: $_"
    exit 1
}

# ==============================================================================
# PHASE 6: NAA CONFIGURATION (SCHEDULED TASK)
# ==============================================================================
Write-Host "`n[DELAY] Sleeping 30 seconds before NAA configuration..." -ForegroundColor Magenta
Start-Sleep -Seconds 30

Start-PhaseTimer -PhaseName "NAA CONFIGURATION ($TargetAdminUser)"
try {
    $TaskName = "CRED1_NAA_Task"
    $TempScript = "C:\Windows\Temp\CRED1_Merged_Exec.ps1"
    $BatchWrapper = "C:\Windows\Temp\RunCRED1NAA.cmd"
    $LogPath = "C:\CRED1_NAA_Log.txt"
    
    # Copy self to temp
    Copy-Item -Path $MyInvocation.MyCommand.Definition -Destination $TempScript -Force
    if (Test-Path $TimerModule) {
        Copy-Item -Path $TimerModule -Destination "C:\Windows\Temp\PhaseTimer.psm1" -Force
    }
    
    # Remove old log
    Remove-Item $LogPath -Force -ErrorAction SilentlyContinue
    
    # Create batch wrapper to call THIS script with -NAAExecutionMode switch
    $BatchContent = @"
@echo off
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "$TempScript" -NAAExecutionMode > "$LogPath" 2>&1
"@
    Set-Content -Path $BatchWrapper -Value $BatchContent -Encoding ASCII
    
    # Register Scheduled Task
    $Action = New-ScheduledTaskAction -Execute $BatchWrapper
    $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    
    Write-Host " [TASK] Registering task to run as $TargetAdminUser..." -ForegroundColor Cyan
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Settings $Settings `
        -User $TargetAdminUser -Password $TargetAdminPass -RunLevel Highest -Force | Out-Null
    
    # Start Task
    Write-Host " [TASK] Starting task..." -ForegroundColor Cyan
    Start-ScheduledTask -TaskName $TaskName
    
    # Wait for completion (max 5 min)
    Write-Host " [WAIT] Waiting for NAA configuration" -NoNewline
    $Timeout = 300
    $Elapsed = 0
    Start-Sleep -Seconds 2
    
    while ($Elapsed -lt $Timeout) {
        $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($Task.State -eq "Ready") { break }
        Write-Host -NoNewline "."
        Start-Sleep -Seconds 2
        $Elapsed += 2
    }
    Write-Host " Done!"
    
    # Display Output
    if (Test-Path $LogPath) {
        Write-Host "`n--- NAA Task Output ---" -ForegroundColor Cyan
        Get-Content $LogPath
    }

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    
    Stop-PhaseTimer -Status Success
}
catch {
    Stop-PhaseTimer -Status Failed
    Write-Error "Phase 6 Failed: $_"
}

# ==============================================================================
# PHASE 7: FINAL VERIFICATION
# ==============================================================================
Start-PhaseTimer -PhaseName "FINAL VERIFICATION"
$AllGood = $true

Write-Host " [CHECK] Boot Images (x86/x64)..." -NoNewline
$Img86 = Get-CMBootImage | Where-Object { $_.Name -like "*x86*" }
$Img64 = Get-CMBootImage | Where-Object { $_.Name -like "*x64*" }
if ($Img86 -and $Img64) { Write-Host " [OK]" -ForegroundColor Green } else { Write-Host " [FAIL]" -ForegroundColor Red; $AllGood = $false }

Write-Host " [CHECK] PXE Service Status..." -NoNewline
$Svc = Get-Service "SccmPxe" -ErrorAction SilentlyContinue
if ($Svc -and $Svc.Status -eq "Running") { Write-Host " [OK]" -ForegroundColor Green } else { Write-Host " [FAIL]" -ForegroundColor Red; $AllGood = $false }

Write-Host " [CHECK] Task Sequence Deployment..." -NoNewline
# Checking deployment to "All Unknown Computers" collection ID 'SMS00004' usually, or verify by Collection Name
$CollUnknown = Get-CMCollection -Name "All Unknown Computers" -ErrorAction SilentlyContinue
if ($CollUnknown) {
    $Dep = Get-CMTaskSequenceDeployment -Fast | Where-Object { $_.CollectionID -eq $CollUnknown.CollectionID }
    if ($Dep) { Write-Host " [OK]" -ForegroundColor Green } else { Write-Host " [FAIL] No deployment found" -ForegroundColor Red; $AllGood = $false }
}
else {
    Write-Host " [FAIL] Collection not found" -ForegroundColor Red; $AllGood = $false
}

Write-Host "`n[COMPLETE] Domain: silent.run | NAA: $NAA_User" -ForegroundColor Magenta
