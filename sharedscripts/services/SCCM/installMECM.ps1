# Install-MECM.ps1 
# ---------------------------------------------------
# 1. Installs Drivers (ODBC + VC++)
# 2. Downloads Prereqs using 'setupdl.exe' (Standalone Tool)
# 3. Installs Site directly from Share
# 4. Streams Log Output to Console

$ErrorActionPreference = "Stop"

# Import Phase Timer Module (Ensure this file is clean!)
Import-Module C:\vagrant\sharedscripts\PhaseTimer.psm1 -Force

# Preserve ConfigMgrSetup.log to the host-visible share and print its tail so failures are diagnosable.
function Save-SetupLog {
    param([string]$LogFile, [string]$ShareRoot)
    if (-not (Test-Path $LogFile)) {
        Write-Host " [WARN] $LogFile not found - setup may not have started." -ForegroundColor Yellow
        return
    }
    $SavedLog = "$ShareRoot\ConfigMgrSetup-FAILED-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    Copy-Item -Path $LogFile -Destination $SavedLog -Force -ErrorAction SilentlyContinue
    Write-Host "`n--- ConfigMgrSetup.log (last 50 lines) ---" -ForegroundColor Yellow
    Get-Content -Path $LogFile -Tail 50 -ErrorAction SilentlyContinue | Write-Host
    Write-Host "--- end log (full copy saved to $SavedLog) ---" -ForegroundColor Yellow
}

# --- CONFIGURATION ---
# NOTE: setup.exe reads the site code/name/server from ConfigMgrAutoSave.ini, which
# duplicates values in lab-config.json. The preflight below asserts they match so a
# drifted INI fails fast here instead of as a confusing ~40-min install failure.
. C:\vagrant\sharedscripts\Get-LabConfig.ps1
$cfg = Get-LabConfig
$SiteCode = $cfg.sccm.siteCode
$SiteName = $cfg.sccm.siteName
$InstallDir = "C:\Program Files\Microsoft Configuration Manager"

# ---- Getting Server Name ----
$IPProps = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
$SDKServer = "{0}.{1}" -f $IPProps.HostName, $IPProps.DomainName
Write-Host "Target Server FQDN: $SDKServer" -ForegroundColor Cyan

# PATHS
$ShareRoot = "C:\vagrant\sharedscripts\services\SCCM\MECM_Setup"
$ShareMedia = "$ShareRoot\Media"
$SharePrereqs = "$ShareRoot\Prereqs"
$IniFile = "$ShareRoot\ConfigMgrAutoSave.ini"

# --- PREFLIGHT: assert the answer file matches lab-config.json ---
# ConfigMgrAutoSave.ini is a static answer file whose values duplicate lab-config.json.
# Fail fast here if they have drifted apart, rather than letting setup.exe build the
# site with stale values (a confusing failure ~40 minutes in).
$SccmFqdn = "$($cfg.hosts.sccm.name).$($cfg.domain.fqdn)"
$expectedIni = [ordered]@{
    'SiteCode'             = $SiteCode
    'SiteName'             = $SiteName
    'SDKServer'            = $SccmFqdn
    'ManagementPoint'      = $SccmFqdn
    'DistributionPoint'    = $SccmFqdn
    'SQLServerName'        = $SccmFqdn
    'DatabaseName'         = "CM_$SiteCode"
    'CloudConnectorServer' = $SccmFqdn
}
if (-not (Test-Path $IniFile)) { throw "MECM answer file not found: $IniFile" }
$iniLines   = Get-Content -Path $IniFile
$iniMismatch = @()
foreach ($key in $expectedIni.Keys) {
    $line = $iniLines | Where-Object { $_ -match "^\s*$key\s*=" } | Select-Object -First 1
    if (-not $line) {
        $iniMismatch += "  $key : MISSING in INI (expected '$($expectedIni[$key])')"
        continue
    }
    $actual = ($line -split '=', 2)[1].Trim()
    if ($actual -ne $expectedIni[$key]) {
        $iniMismatch += "  $key : INI has '$actual' but lab-config expects '$($expectedIni[$key])'"
    }
}
if ($iniMismatch.Count -gt 0) {
    throw ("ConfigMgrAutoSave.ini is out of sync with lab-config.json:`n" + ($iniMismatch -join "`n") +
        "`nEdit sharedscripts/services/SCCM/MECM_Setup/ConfigMgrAutoSave.ini to match lab-config.json, then re-run.")
}
Write-Host " [OK] ConfigMgrAutoSave.ini matches lab-config.json (site $SiteCode, server $SccmFqdn)." -ForegroundColor Green

# --- FAST IDEMPOTENCY: skip the ~40-min site install if MECM is already installed ---
# A completed Primary Site setup leaves ALL THREE of: the SMS Setup registry key, the
# SMS_EXECUTIVE service, and a queryable SMS provider namespace (root\SMS\site_<code>).
# Requiring all three avoids re-running setup.exe on a re-provision, yet still reinstalls
# if a prior run died partway (any one missing -> fall through and install normally).
$mecmInstalled = $false
try {
    $smsReg  = Test-Path "HKLM:\SOFTWARE\Microsoft\SMS\Setup"
    $smsSvc  = [bool](Get-Service -Name "SMS_EXECUTIVE" -ErrorAction SilentlyContinue)
    $smsSite = $null
    try { $smsSite = Get-WmiObject -Namespace "root\SMS\site_$SiteCode" -Class SMS_Site -ErrorAction Stop } catch { }
    $mecmInstalled = ($smsReg -and $smsSvc -and $smsSite)
} catch { $mecmInstalled = $false }

if ($mecmInstalled) {
    Write-Host " [SKIP] MECM site '$SiteCode' already installed (SMS registry + SMS_EXECUTIVE + SMS provider all present)." -ForegroundColor Green
    Write-Host " [SKIP] Skipping the ~40-min site install. Destroy/rebuild the VM to force a clean reinstall." -ForegroundColor Green
    exit 0
}

# --- STEP 0: FIX NETWORK & DNS ---
Start-PhaseTimer -PhaseName "VERIFYING CONNECTIVITY"
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    & "C:\vagrant\sharedscripts\networking\configure-network.ps1" -Action NatInternetDns
    if (Test-Connection "google.com" -Count 1 -Quiet) { 
        Write-Host " [OK] Internet Connected." -ForegroundColor Green 
        Stop-PhaseTimer -Status Success
    }
    else {
        Stop-PhaseTimer -Status Warning
    }
}
catch { 
    Stop-PhaseTimer -Status Warning
    Write-Warning "DNS Check skipped." 
}


# --- STEP 1: INSTALL DRIVERS ---
Start-PhaseTimer -PhaseName "INSTALLING DRIVERS (ODBC & VC++)"

# 1. ODBC Driver 18
if (Get-Package -Name "Microsoft ODBC Driver 18 for SQL Server" -ErrorAction SilentlyContinue) {
    Write-Host "ODBC Driver 18 is already installed." -ForegroundColor Green
}
else {
    Write-Host "Downloading ODBC Driver 18..." -ForegroundColor Yellow
    $ODBCPath = "$ShareRoot\msodbcsql.msi"
    
    if (-not (Test-Path $ODBCPath)) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri "https://go.microsoft.com/fwlink/?linkid=2220989" -OutFile $ODBCPath -UseBasicParsing
        }
        catch { Write-Warning "Could not download ODBC driver." }
    }

    if (Test-Path $ODBCPath) {
        Write-Host "Installing ODBC Driver..."
        Start-Process -FilePath "msiexec.exe" -ArgumentList "/i", "`"$ODBCPath`"", "/qn", "/norestart", "IACCEPTMSODBCSQLLICENSETERMS=YES" -Wait
        Write-Host "ODBC Installed." -ForegroundColor Green
    }
}

# 2. VC++ Redistributable 
$VCRedist = Get-ChildItem -Path $ShareMedia -Filter "vcredist_x64.exe" -Recurse | Select-Object -First 1
if ($VCRedist) {
    Write-Host "Installing VC++ Redistributable..."
    Start-Process -FilePath $VCRedist.FullName -ArgumentList "/install", "/quiet", "/norestart" -Wait
}
Stop-PhaseTimer -Status Success

# --- STEP 1.5: CHECK MEDIA & DOWNLOAD ---
Start-PhaseTimer -PhaseName "CHECKING INSTALLATION MEDIA"
$EvalExe = "$ShareRoot\MEM_Configmgr_Eval.exe"
# Direct Link to MECM 2403 Evaluation 
$EvalUrl = "https://go.microsoft.com/fwlink/p/?LinkID=2195628" 

# Check if Media seems present (look for setup.exe)
$MediaCheck = Get-ChildItem -Path $ShareMedia -Filter "setup.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1

if (-not $MediaCheck) {
    Write-Host "MECM Media (setup.exe) not found in '$ShareMedia'." -ForegroundColor Yellow
    
    # Check if we have the Eval Executable
    if (-not (Test-Path $EvalExe)) {
        Write-Host "Downloading MEM_Configmgr_Eval.exe (This is 1.2GB, may take time)..." -ForegroundColor Cyan
        try {
            # BITS is reliable for large files
            Start-BitsTransfer -Source $EvalUrl -Destination $EvalExe -ErrorAction Stop
            Write-Host "Download Complete." -ForegroundColor Green
        }
        catch {
            Write-Warning "BITS Failed. Trying WebRequest..."
            try {
                Invoke-WebRequest -Uri $EvalUrl -OutFile $EvalExe -UseBasicParsing -TimeoutSec 3600
            }
            catch {
                Write-Error "Failed to download MECM Media. Please download manually."
            }
        }
    }
    else {
        Write-Host "Found existing MEM_Configmgr_Eval.exe." -ForegroundColor Green
    }
    
    # Attempt Extraction using Native Self-Extractor
    if (Test-Path $EvalExe) {
        Write-Host "Extracting Media (This may take a few minutes)..." -ForegroundColor Cyan
        
        # Command: -d"Path" -s1 (Silent)
        $ExtractArgs = "-d`"$ShareMedia`" -s1"
        $Process = Start-Process -FilePath $EvalExe -ArgumentList $ExtractArgs -Wait -PassThru
        
        if ($Process.ExitCode -eq 0) {
            Write-Host "Extraction Complete." -ForegroundColor Green
             
            # Re-verify
            $MediaCheck = Get-ChildItem -Path $ShareMedia -Filter "setup.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($MediaCheck) { Write-Host "Verified: setup.exe found." -ForegroundColor Green }
        }
        else {
            Write-Warning "Extraction exited with code $($Process.ExitCode). Please check '$ShareMedia'."
        }
    }
}
else {
    Write-Host "MECM Media found." -ForegroundColor Green
}
Stop-PhaseTimer -Status Success
Start-PhaseTimer -PhaseName "DOWNLOADING PREREQUISITES"

if (-not (Test-Path $SharePrereqs)) { New-Item -Path $SharePrereqs -ItemType Directory -Force | Out-Null }
$PrereqCount = @(Get-ChildItem -Path $SharePrereqs -File).Count
if ($PrereqCount -lt 50) {
    # Find setupdl.exe
    $SetupDlExe = Get-ChildItem -Path $ShareMedia -Filter "setupdl.exe" -Recurse | Select-Object -First 1
    
    if ($SetupDlExe) {
        Write-Host "Found Standalone Downloader: $($SetupDlExe.FullName)"
        Write-Host "Downloading Prerequisites directly to Share..." -ForegroundColor Yellow
        
        $Proc = Start-Process -FilePath $SetupDlExe.FullName -ArgumentList "/NOUI", "$SharePrereqs" -Wait -PassThru
        
        if ($Proc.ExitCode -eq 0) {
            Write-Host "Prerequisites Downloaded Successfully." -ForegroundColor Green
            Stop-PhaseTimer -Status Success
        }
        else {
            Stop-PhaseTimer -Status Failed
            Write-Error "Download Failed. Exit Code: $($Proc.ExitCode)."
            exit 1
        }
    }
    else {
        Stop-PhaseTimer -Status Failed
        Write-Error "CRITICAL: setupdl.exe not found in media!"
        exit 1
    }
}
else {
    Write-Host "Prerequisites found ($PrereqCount files)." -ForegroundColor Green
    Stop-PhaseTimer -Status Success
}

# --- STEP 3: CONFIGURE & INSTALL ---
Start-PhaseTimer -PhaseName "INSTALLING MECM SITE"

# Locate Setup.exe
$SetupExe = Get-ChildItem -Path $ShareMedia -Filter "setup.exe" -Recurse | Where-Object { $_.FullName -like "*BIN\X64*" } | Select-Object -First 1
if (-not $SetupExe) { Write-Error "CRITICAL: setup.exe not found!"; exit 1 }

$WorkDir = $SetupExe.Directory.FullName
Push-Location -Path $WorkDir
$SetupArgs = @("/Script", "$IniFile", "/NoUserInput")

Write-Host "Starting Installation ..."

# Archive old log
if (Test-Path "C:\ConfigMgrSetup.log") {
    $TimeStamp = Get-Date -Format "yyyyMMdd-HHmmss"
    Rename-Item -Path "C:\ConfigMgrSetup.log" -NewName "ConfigMgrSetup_$TimeStamp.log" -ErrorAction SilentlyContinue
}

try {
    # Execute Setup in Background
    $Process = Start-Process -FilePath ".\setup.exe" -ArgumentList $SetupArgs -PassThru
    
    Write-Host "Setup started (PID: $($Process.Id))." 
    Write-Host "Streaming log output every minute to make sure the installation is running ..." 

    $LogFile = "C:\ConfigMgrSetup.log"
    
    # Wait for log file
    while (-not (Test-Path $LogFile)) {
        Start-Sleep -Seconds 2
        Write-Host "." -NoNewline
    }
    Write-Host "`nLog found. Monitoring..."

    # --- LIVE LOG STREAMING LOOP ---
    $SuccessRegex = "Core setup has completed|Completed Configuration Manager Server Setup"
    $FailureRegex = "Setup has encountered a fatal error|Setup failed|Failed Configuration Manager Server Setup"
    
    $LastLogLine = ""
    $SetupOutcome = "Unknown"

    while ($true) {
        if ($Process.HasExited) {
            Write-Host "`nSetup process exited." -ForegroundColor Yellow
            $SetupOutcome = "Exited"
            break
        }
        
        # Read the last 5 lines, pick the last non-empty one
        $CurrentContent = Get-Content -Path $LogFile -Tail 5 -ErrorAction SilentlyContinue
        $CurrentLine = $CurrentContent | Where-Object { $_ -match "\S" } | Select-Object -Last 1
        
        # Check Success/Failure
        if ($CurrentContent -match $SuccessRegex) {
            Write-Host "`nSUCCESS: Installation Completed Successfully!" -ForegroundColor Green
            $SetupOutcome = "Success"
            break
        }
        if ($CurrentContent -match $FailureRegex) {
            Write-Host "`nFAILURE: Setup encountered an error. Check logs." -ForegroundColor Red
            $SetupOutcome = "Failure"
            break
        }
        
        # If the log line is new, print it
        if ($CurrentLine -and $CurrentLine -ne $LastLogLine) {
            $LastLogLine = $CurrentLine
            
            # Truncate strictly for display cleanliness
            $DisplayLine = if ($CurrentLine.Length -gt 110) { $CurrentLine.Substring(0, 107) + "..." } else { $CurrentLine }
            
            # Print without newlines to simulate a status bar, OR just print log lines
            # For Vagrant, simple Write-Host is safer than carriage returns
            $Time = Get-Date -Format "HH:mm:ss"
            Write-Host " [$Time] $DisplayLine" -ForegroundColor Gray
        }
        
        Start-Sleep -Seconds 60
    }

    # --- Resolve the true outcome. Markers can scroll past the 5-line tail, so scan the full log. ---
    $FullLog = Get-Content -Path $LogFile -ErrorAction SilentlyContinue
    if ($SetupOutcome -ne "Success") {
        if ($FullLog -match $SuccessRegex) { $SetupOutcome = "Success" }
        elseif ($FullLog -match $FailureRegex) { $SetupOutcome = "Failure" }
    }

    if ($SetupOutcome -ne "Success") {
        Save-SetupLog -LogFile $LogFile -ShareRoot $ShareRoot
        Stop-PhaseTimer -Status Failed
        Write-Host "MECM Setup did not complete successfully (outcome: $SetupOutcome)." -ForegroundColor Red
        exit 1
    }

    Stop-PhaseTimer -Status Success

    # --- STEP 4: VERIFY INSTALLATION ---
    Start-PhaseTimer -PhaseName "VERIFYING INSTALLATION"

    $VerificationFailed = $false
    $Services = "SMS_EXECUTIVE", "SMS_SITE_COMPONENT_MANAGER"

    # Site services can take a minute or two to register after core setup completes - give a grace period.
    Write-Host "Waiting for site services to register..." -ForegroundColor Gray
    $SvcWait = 0
    while ($SvcWait -lt 180) {
        $exec = Get-Service -Name "SMS_EXECUTIVE" -ErrorAction SilentlyContinue
        if ($exec -and $exec.Status -eq 'Running') { break }
        Start-Sleep -Seconds 10
        $SvcWait += 10
    }

    # 1. Check Services
    foreach ($Svc in $Services) {
        $Status = Get-Service -Name $Svc -ErrorAction SilentlyContinue
        if ($Status -and $Status.Status -eq 'Running') {
            Write-Host " [OK] Service '$Svc' is Running." -ForegroundColor Green
        }
        elseif ($Status) {
            Write-Host " [FAIL] Service '$Svc' exists but is $($Status.Status)." -ForegroundColor Red
            $VerificationFailed = $true
        }
        else {
            Write-Host " [FAIL] Service '$Svc' not found." -ForegroundColor Red
            $VerificationFailed = $true
        }
    }

    # 2. Check Registry
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\SMS\Setup") {
        Write-Host " [OK] SMS Registry Keys exist." -ForegroundColor Green
    }
    else {
        Write-Host " [FAIL] Missing SMS Registry Keys." -ForegroundColor Red
        $VerificationFailed = $true
    }

    if ($VerificationFailed) {
        Save-SetupLog -LogFile $LogFile -ShareRoot $ShareRoot
        Stop-PhaseTimer -Status Failed
        Write-Host "CRITICAL: Installation Verification FAILED." -ForegroundColor Red
        exit 1
    }
    else {
        Write-Host "Installation Verification PASSED. MECM is ready." -ForegroundColor Green
        Stop-PhaseTimer -Status Success
    }
}
catch {
    Stop-PhaseTimer -Status Failed
    Write-Error "Failed to execute setup.exe. Error Details: $_"
    exit 1
}

# ==============================================================================
# STEP 5: WAIT FOR MANAGEMENT POINT FINALIZATION (CRITICAL)
# ==============================================================================
Start-PhaseTimer -PhaseName "WAITING FOR MP INSTALLATION"
Write-Host " [INFO] Core Setup complete. Waiting for Management Point to finalize..." -ForegroundColor Yellow

# Max wait time: 20 minutes (usually takes 5-10 mins)
$MaxWaitSeconds = 1200 
$Timer = 0
$MPInstalled = $false

while ($Timer -lt $MaxWaitSeconds) {
    # check status via WMI
    $CompStatus = Get-WmiObject -Namespace "root\SMS\site_$SiteCode" -Class SMS_ComponentSummarizer -Filter "ComponentName = 'SMS_MP_CONTROL_MANAGER'" -ErrorAction SilentlyContinue
    
    # Status 0 = Installed OK (Green)
    if ($CompStatus -and $CompStatus.Status -eq 0) { 
        Write-Host "`n [OK] MP Component Status is Green (Ready for Reboot)." -ForegroundColor Green
        $MPInstalled = $true
        break
    }
    
    # Optional: Check log file for specific success line
    $LogPath = "C:\Program Files\Microsoft Configuration Manager\Logs\MPSetup.log"
    if (Test-Path $LogPath) {
        $LogContent = Get-Content $LogPath -Tail 20 -ErrorAction SilentlyContinue | Out-String
        if ($LogContent -match "Installation was successful") {
            Write-Host "`n [OK] MPSetup.log confirms success." -ForegroundColor Green
            Start-Sleep -Seconds 60
            Write-Host "`n [OK] Management Point is ready for reboot." -ForegroundColor Green
            $MPInstalled = $true
            break
        }
    }

    Write-Host -NoNewline "."
    Start-Sleep -Seconds 15
    $Timer += 15
}

if (-not $MPInstalled) {
    Write-Warning " [WARN] Management Point installation timed out. Proceeding, but verify logs after reboot."
}

Stop-PhaseTimer -Status Success

Show-InstallationSummary