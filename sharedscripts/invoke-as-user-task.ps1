# invoke-as-user-task.ps1
# ------------------------------------------------------------------------------
# Shared helper: run a script under a REAL logon token via a one-shot scheduled
# task, then clean up. Dot-source this file, then call Invoke-AsUserTask.
#
# Why this exists: Vagrant's WinRM shell provisioner runs under a token that
# cannot perform certain operations (AD schema changes as Schema-Admin, GMSA/KDS,
# the SCCM SMS provider, Kerberos double-hop). A one-shot task with /rl highest
# gives a proper batch (or SYSTEM) logon token. This replaces ~5 hand-rolled
# copies of the same create -> run -> poll-status -> delete dance.
#
# Two input modes:
#   -ScriptContent <string>  : the helper writes it to a temp .ps1 and runs that.
#   -ScriptPath <path>       : the helper runs an existing file in place (keeps
#                              its $PSScriptRoot, e.g. for self-elevation scripts).
#
# Identity:
#   -User '' or 'SYSTEM'     : run as NT AUTHORITY\SYSTEM (no password).
#   -User 'DOMAIN\User' + -Password : run as that user.
#
# Returns $true only when the inner script completed without throwing.
# ------------------------------------------------------------------------------

function Invoke-AsUserTask {
    [CmdletBinding(DefaultParameterSetName = 'Content')]
    param(
        [Parameter(Mandatory = $true)] [string] $Name,
        [Parameter(Mandatory = $true, ParameterSetName = 'Content')] [string] $ScriptContent,
        [Parameter(Mandatory = $true, ParameterSetName = 'Path')]    [string] $ScriptPath,
        [string] $User,
        [string] $Password,
        [int]    $TimeoutSec = 120
    )

    $safe    = ($Name -replace '[^A-Za-z0-9]', '_')
    $wrapper = "C:\${safe}_wrapper.ps1"
    $status  = "C:\${safe}_status.txt"
    $log     = "C:\${safe}_log.txt"

    # In Content mode, materialise the inner script to a temp file we own.
    $ownInner = $false
    if ($PSCmdlet.ParameterSetName -eq 'Content') {
        $ScriptPath = "C:\${safe}_inner.ps1"
        $ScriptContent | Out-File -FilePath $ScriptPath -Encoding UTF8
        $ownInner = $true
    }

    Remove-Item $status, $log -Force -ErrorAction SilentlyContinue

    # Wrapper records SUCCESS/FAILED and captures all output to a log.
    @"
try { & "$ScriptPath" *>> "$log"; "SUCCESS" | Out-File "$status" }
catch { `$_.Exception.Message | Out-File "$log" -Append; "FAILED" | Out-File "$status" }
"@ | Out-File -FilePath $wrapper -Encoding UTF8

    $tr = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$wrapper`""
    # Schedule for tomorrow so /st is never in the past. Otherwise schtasks prints
    # "WARNING: Task may not run because /ST is earlier than current time" to stderr,
    # which trips the invoke-vagrant-script.ps1 Stop/trap. We run the task immediately via /run anyway,
    # so the scheduled time is irrelevant.
    $startDate = (Get-Date).AddDays(1).ToString('MM/dd/yyyy')
    if ([string]::IsNullOrWhiteSpace($User) -or $User -eq 'SYSTEM') {
        schtasks /create /f /tn $Name /sc once /sd $startDate /st 00:00 /rl highest /ru "SYSTEM" /tr $tr 2>&1 | Out-Null
    } else {
        schtasks /create /f /tn $Name /sc once /sd $startDate /st 00:00 /rl highest /ru $User /rp $Password /tr $tr 2>&1 | Out-Null
    }

    # schtasks defaults DisallowStartIfOnBatteries=True. These VMs expose a phantom
    # battery (Win32_Battery BatteryStatus=1 "on battery"), so the on-demand instance
    # sticks in "Queued" forever (TaskScheduler event 325) and never runs the action.
    # Clear the battery guard; everything else keeps the schtasks defaults.
    # Set-ScheduledTask re-registers the task, which drops a stored password, so the
    # user path must re-supply -User/-Password or the Administrator logon fails.
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    if ([string]::IsNullOrWhiteSpace($User) -or $User -eq 'SYSTEM') {
        Set-ScheduledTask -TaskName $Name -Settings $set -ErrorAction SilentlyContinue | Out-Null
    } else {
        Set-ScheduledTask -TaskName $Name -Settings $set -User $User -Password $Password -ErrorAction SilentlyContinue | Out-Null
    }

    schtasks /run /tn $Name 2>&1 | Out-Null

    $elapsed = 0
    while ($elapsed -lt $TimeoutSec) {
        Start-Sleep -Seconds 5
        $elapsed += 5
        if (Test-Path $status) { break }
        if ($elapsed % 30 -eq 0) { Write-Host "  [$Name] still running... ($elapsed s)" }
    }

    $ok = $false
    if (Test-Path $status) {
        $result = (Get-Content $status -Raw).Trim()
        Write-Host "  [$Name] status: $result"
        if (Test-Path $log) { Get-Content $log | Write-Host }
        $ok = ($result -eq 'SUCCESS')
    } else {
        Write-Host "  [$Name] timed out after $TimeoutSec s" -ForegroundColor Red
        if (Test-Path $log) { Get-Content $log | Write-Host }
    }

    schtasks /delete /tn $Name /f 2>&1 | Out-Null
    Remove-Item $wrapper, $status, $log -Force -ErrorAction SilentlyContinue
    if ($ownInner) { Remove-Item $ScriptPath -Force -ErrorAction SilentlyContinue }

    return $ok
}
