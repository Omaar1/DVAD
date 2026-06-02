# verify-lab.ps1
# Post-provisioning health check for SilentRUN-Lab.
# Tests IP reachability, WinRM connectivity, and key service status.

. "$PSScriptRoot\sharedscripts\Get-LabConfig.ps1"
$cfg = Get-LabConfig

$vms = @(
    @{ Name = "RootDC";      IP = $cfg.hosts.rootdc.ip; Services = @("ADWS", "DNS", "Netlogon", "NTDS") },
    @{ Name = "ADCS_server"; IP = $cfg.hosts.adcs.ip;   Services = @("CertSvc", "W3SVC") },
    @{ Name = "SCCM_server"; IP = $cfg.hosts.sccm.ip;   Services = @("SMS_Executive", "MSSQLSERVER", "W3SVC") },
    @{ Name = "SVR1";        IP = $cfg.hosts.svr1.ip;   Services = @("Workstation") }
)

$pass   = ConvertTo-SecureString $cfg.domain.administratorPassword -AsPlainText -Force
$cred   = New-Object System.Management.Automation.PSCredential("$($cfg.domain.netbiosName)\Administrator", $pass)

$allOk = $true

Write-Host "======================================" -ForegroundColor Cyan
Write-Host " SilentRUN-Lab Health Check" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan

foreach ($vm in $vms) {
    Write-Host ""
    Write-Host "--- $($vm.Name) ($($vm.IP)) ---" -ForegroundColor Yellow

    # Ping
    $ping = Test-Connection -ComputerName $vm.IP -Count 1 -Quiet -ErrorAction SilentlyContinue
    if ($ping) {
        Write-Host "  [PING] OK" -ForegroundColor Green
    } else {
        Write-Host "  [PING] FAIL — VM may be down" -ForegroundColor Red
        $allOk = $false
        continue
    }

    # WinRM
    try {
        $session = New-PSSession -ComputerName $vm.IP -Credential $cred `
            -SessionOption (New-PSSessionOption -SkipCACheck -SkipCNCheck) `
            -Authentication Basic -ErrorAction Stop
        Write-Host "  [WINRM] Connected" -ForegroundColor Green

        # Service checks
        foreach ($svc in $vm.Services) {
            $status = Invoke-Command -Session $session -ScriptBlock {
                param($s)
                $service = Get-Service -Name $s -ErrorAction SilentlyContinue
                if ($service) { $service.Status } else { "NotFound" }
            } -ArgumentList $svc
            if ($status -eq "Running") {
                Write-Host "  [SVC] $svc : Running" -ForegroundColor Green
            } else {
                Write-Host "  [SVC] $svc : $status" -ForegroundColor Red
                $allOk = $false
            }
        }
        Remove-PSSession $session
    } catch {
        Write-Host "  [WINRM] FAIL — $_" -ForegroundColor Red
        $allOk = $false
    }
}

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
if ($allOk) {
    Write-Host " All checks passed — lab is healthy" -ForegroundColor Green
} else {
    Write-Host " Some checks failed — review output above" -ForegroundColor Red
}
Write-Host "======================================" -ForegroundColor Cyan
