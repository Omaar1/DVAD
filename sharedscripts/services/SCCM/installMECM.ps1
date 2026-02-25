# Install-MECM.ps1 
# ---------------------------------------------------
# 1. Installs Drivers (ODBC + VC++)
# 2. Downloads Prereqs using 'setupdl.exe' (Standalone Tool)
# 3. Installs Site directly from Share
# 4. Streams Log Output to Console

$ErrorActionPreference = "Stop"

# Import Phase Timer Module (Ensure this file is clean!)
Import-Module "$PSScriptRoot\PhaseTimer.psm1" -Force

# --- CONFIGURATION ---
$SiteCode = "PS1"
$SiteName = "LabPrimary"
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

# --- STEP 0: FIX NETWORK & DNS ---
Start-PhaseTimer -PhaseName "VERIFYING CONNECTIVITY"
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses ("8.8.8.8", "8.8.4.4") -ErrorAction SilentlyContinue
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
    
    while ($true) {
        if ($Process.HasExited) {
            Write-Host "`nSetup process exited." -ForegroundColor Yellow
            break
        }
        
        # Read the last 5 lines, pick the last non-empty one
        $CurrentContent = Get-Content -Path $LogFile -Tail 5 -ErrorAction SilentlyContinue
        $CurrentLine = $CurrentContent | Where-Object { $_ -match "\S" } | Select-Object -Last 1
        
        # Check Success/Failure
        if ($CurrentContent -match $SuccessRegex) {
            Write-Host "`nSUCCESS: Installation Completed Successfully!" -ForegroundColor Green
            break
        }
        if ($CurrentContent -match $FailureRegex) {
            Write-Host "`nFAILURE: Setup encountered an error. Check logs." -ForegroundColor Red
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
    
    Stop-PhaseTimer -Status Success
    
    # --- STEP 4: VERIFY INSTALLATION ---
    Start-PhaseTimer -PhaseName "VERIFYING INSTALLATION"

    $VerificationFailed = $false

    # 1. Check Services
    $Services = "SMS_EXECUTIVE", "SMS_SITE_COMPONENT_MANAGER"
    foreach ($Svc in $Services) {
        $Status = Get-Service -Name $Svc -ErrorAction SilentlyContinue
        if ($Status -and $Status.Status -eq 'Running') {
            Write-Host " [OK] Service '$Svc' is Running." -ForegroundColor Green
        }
        elseif ($Status) {
            Write-Error " [FAIL] Service '$Svc' exists but is $($Status.Status)."
            $VerificationFailed = $true
        }
        else {
            Write-Error " [FAIL] Service '$Svc' not found."
            $VerificationFailed = $true
        }
    }

    # 2. Check Registry
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\SMS\Setup") {
        Write-Host " [OK] SMS Registry Keys exist." -ForegroundColor Green
    }
    else {
        Write-Error " [FAIL] Missing SMS Registry Keys."
        $VerificationFailed = $true
    }

    if ($VerificationFailed) {
        Stop-PhaseTimer -Status Failed
        Write-Error "CRITICAL: Installation Verification FAILED."
        # DO NOT throw here; just exit with a non-zero code
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