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
$TimerModule = "C:\vagrant\provisioners\phase-timer.psm1"
if (Test-Path $TimerModule) { Import-Module $TimerModule -Force -ErrorAction SilentlyContinue } 

# --- CONFIGURATION VARIABLES ---
. C:\vagrant\provisioners\get-lab-config.ps1
$cfg = Get-LabConfig
$netbios = $cfg.domain.netbiosName
$SiteCode = $cfg.sccm.siteCode
$SiteServer = "$($cfg.hosts.sccm.name).$($cfg.domain.fqdn)"
$BoundaryIP = $cfg.network.subnet
$BoundaryName = "Lab Subnet"
$Group = "Lab Boundary Group"
$NAA_User = "$netbios\$($cfg.sccm.accounts.networkAccess)"
$NAA_Pass = $cfg.sccm.accountPassword
$TargetAdminUser = "$netbios\Administrator"
$TargetAdminPass = $cfg.domain.administratorPassword

# ==============================================================================
# NAA EXECUTION MODE (Called via Scheduled Task as DVAD\Administrator)
# ==============================================================================
if ($NAAExecutionMode) {
    Start-Transcript -Path "C:\CRED1_NAA_Exec_Log.txt" -Force
    Write-Host "--- NAA SUB-PROCESS STARTED ---" -ForegroundColor Cyan
    
    # 1. Load module + connect to site
    try {
        . C:\vagrant\provisioners\services\SCCM\connect-cm-site.ps1
        Connect-CMSite -SiteCode $SiteCode -SiteServer $SiteServer
    }
    catch {
        Write-Error $_
        Stop-Transcript
        exit 1
    }

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
. C:\vagrant\provisioners\services\SCCM\connect-cm-site.ps1
Connect-CMSite -SiteCode $SiteCode -SiteServer $SiteServer

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
# PHASE 2: POST-MECM HOST FIXES (NTFS ACLs + Name Resolution)
# ------------------------------------------------------------------------------
# Scope note: MECM 2403 already configures SMS_MP anonymous auth correctly for an
# HTTP site (verified: anon=True out of the box). The MP/DP errors this lab hit
# were NOT auth-layer problems -- they were NTFS (worker couldn't read web.config)
# and name resolution (PXE responder reached ::1). Those are the only two real
# fixes, handled below. The IIS unlock is kept only because it's a cheap, real
# prerequisite if any later phase needs to write web-config sections.
# ==============================================================================
Start-PhaseTimer -PhaseName "POST-MECM HOST FIX"
try {
    # --------------------------------------------------------------------------
    # 2A. NTFS ACL FIX -- the actual cause of 500.19 / 403.2.
    # MECM baseline grants LOCAL SERVICE / IUSR container-inherit (CI) only, so
    # inherited ACEs never land on files (web.config). Re-grant with object-
    # inherit (OI); /T forces it down branches with inheritance disabled
    # (ServiceData\System\request). SIDs: S-1-5-19=LOCAL SERVICE, S-1-5-17=IUSR.
    # --------------------------------------------------------------------------
    $ccmRoot = "C:\Program Files\SMS_CCM"
    if (Test-Path $ccmRoot) {
        Write-Host " [INFO] Repairing NTFS ACL inheritance on SMS_CCM..." -ForegroundColor Gray
        & icacls $ccmRoot /grant "*S-1-5-19:(OI)(CI)(RX)" "*S-1-5-17:(OI)(CI)(RX)" /T /C 2>$null | Out-Null
        Write-Host " [OK] LOCAL SERVICE + IUSR granted (OI)(CI)(RX) on SMS_CCM tree." -ForegroundColor Green
    }
    else {
        Write-Warning "SMS_CCM not found; MP role may not be installed. Skipping ACL fix."
    }

    # --------------------------------------------------------------------------
    # 2B. NAME RESOLUTION PIN -- fixes PXE 'RequestMPKeyInformation: Send() failed'
    # 0x80004005. FQDN resolves to ::1 + lab NIC + NAT NIC; ::1 sorts first, so
    # the responder's MP call hits IPv6 loopback and transport init dies. Pin the
    # FQDN to the lab NIC and deprioritize ::1 so IPv4 wins. Idempotent.
    # --------------------------------------------------------------------------
    Write-Host " [INFO] Pinning site server name to lab NIC..." -ForegroundColor Gray
    $SiteFqdn  = $SiteServer
    $SiteHost  = $cfg.hosts.sccm.name
    $LabIP     = $cfg.hosts.sccm.ip
    $hostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"

    (Get-Content $hostsFile) -notmatch [regex]::Escape($SiteFqdn) | Set-Content $hostsFile -Encoding ASCII
    "$LabIP`t$SiteFqdn`t$SiteHost" | Add-Content $hostsFile -Encoding ASCII
    & netsh interface ipv6 set prefixpolicy ::1/128 3 0 2>$null | Out-Null
    & ipconfig /flushdns | Out-Null
    Write-Host " [OK] $SiteFqdn pinned to $LabIP; ::1 deprioritized." -ForegroundColor Green

    # --------------------------------------------------------------------------
    # 2C. IIS settle -- recycle so the ACL change is picked up by worker procs,
    # and restart the PXE responder (service is 'sccmpxe', NOT WDSServer) so it
    # re-resolves the now-pinned name. Responder may not exist until PXE is
    # enabled in a later phase -- SilentlyContinue handles that cleanly.
    # --------------------------------------------------------------------------
    iisreset /restart /timeout:30
    Restart-Service sccmpxe -Force -ErrorAction SilentlyContinue

    Write-Host " [OK] Host fixes applied (NTFS ACL + name pin)." -ForegroundColor Green
    Stop-PhaseTimer -Status Success
}
catch {
    Stop-PhaseTimer -Status Warning
    Write-Warning "Phase 2 Host Fix Failed: $_"
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

        # Distribute to the DP FIRST so the boot WIM is staged regardless of whether the
        # PXE-deploy flag set succeeds. (Previously a failure in the PXE block threw out
        # of this function and skipped distribution, leaving the x64 WIM off the DP.)
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

        if (-not $EnablePxe) { return }

        # Enable "Deploy this boot image from the PXE-enabled DP". Set-CMBootImage's
        # WinPE-version gate has falsely rejected fully-resolved WinPE 10 images passed
        # via -InputObject ("legacy WinPE 3.1 or earlier"). Driving the cmdlet by -Name
        # forces it to load the image server-side (the same fix the -Name Get uses); we
        # also retry in case the SMS Provider lags right after a fresh site install.
        # Non-fatal: the WIM is already distributed above.
        $pxeSet = $false
        for ($i = 0; $i -lt 4; $i++) {
            $img   = Get-CMBootImage -Name $BootImg.Name
            $osVer = $img.ImageOSVersion
            if ($osVer -like "6.0.*" -or $osVer -like "6.1.*") {
                Write-Host " [SKIP] '$($BootImg.Name)' is genuinely legacy WinPE ($osVer); not PXE-enabling." -ForegroundColor Yellow
                $pxeSet = $true
                break
            }
            try {
                Set-CMBootImage -Name $BootImg.Name -DeployFromPxeDistributionPoint $true -ErrorAction Stop
                Write-Host " [OK] PXE deploy flag set on '$($BootImg.Name)' (WinPE $osVer)." -ForegroundColor Green
                $pxeSet = $true
                break
            }
            catch {
                Write-Host " [RETRY $($i + 1)/4] PXE flag set failed (WinPE '$osVer'): $($_.Exception.Message)" -ForegroundColor DarkGray
                Start-Sleep -Seconds 20
            }
        }
        if (-not $pxeSet) {
            Write-Warning "Could not set the PXE-deploy flag on '$($BootImg.Name)' after retries; PXE boot of this image may not work. The boot image IS distributed to the DP."
        }
    }

    # Process Images
    Enable-And-DistributeBootImage -BootImg $BootImgX86 -EnablePxe:$false
    Enable-And-DistributeBootImage -BootImg $BootImgX64 -EnablePxe:$true

    # Poll until the x64 boot image finishes staging on the DP rather than a flat sleep.
    # State on a slow lab disk can take well over a minute; racing Phase 5 (PXE enable)
    # ahead of staging is what leaves the boot WIM "not distributed to this PXE DP".
    Write-Host " [INFO] Waiting for x64 boot image content to stage..." -ForegroundColor Yellow
    $pkgId   = $BootImgX64.PackageID
    $maxWait = 300   # seconds; lab safety ceiling
    $waited  = 0
    do {
        Start-Sleep -Seconds 10
        $waited += 10
        $status = Get-CMDistributionStatus -Id $pkgId -ErrorAction SilentlyContinue
        $inProg = if ($status) { $status.NumberInProgress } else { 0 }
        Write-Host " [INFO] Staging... ($waited s elapsed, $inProg in progress)" -ForegroundColor Gray
    } while ($inProg -gt 0 -and $waited -lt $maxWait)

    if ($status -and $status.NumberInProgress -gt 0) {
        Write-Host " [WARN] Boot image still staging after ${maxWait}s; Phase 5 may need a retry." -ForegroundColor Yellow
    }
    else {
        Write-Host " [OK] x64 boot image staging complete." -ForegroundColor Green
    }

    Stop-PhaseTimer -Status Success

}
catch {
    Stop-PhaseTimer -Status Failed
    # Warning, not Error: wrapper runs ErrorActionPreference=Stop, so Write-Error here
    # would terminate the run and skip Phases 5-7 (PXE enable, TS deploy, NAA config).
    Write-Warning "Phase 4 Failed: $_"
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
        Copy-Item -Path $TimerModule -Destination "C:\Windows\Temp\phase-timer.psm1" -Force
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

Write-Host "`n[COMPLETE] Domain: $($cfg.domain.fqdn) | NAA: $NAA_User" -ForegroundColor Magenta

Show-InstallationSummary
