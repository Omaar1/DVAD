# null-session.ps1
# Configures null session (unauthenticated) access to IPC$ share.
# Attack: smbclient -N //10.10.10.100/IPC$ or enum4linux -a 10.10.10.100

Write-Host "[*] Configuring null session access to IPC$..." -ForegroundColor Cyan

try {
    # Allow null session access via registry
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters"
    Set-ItemProperty -Path $regPath -Name "RestrictNullSessAccess" -Value 0 -Type DWord
    Write-Host "[+] RestrictNullSessAccess set to 0" -ForegroundColor Green

    # Allow null session pipes
    $pipes = @("srvsvc", "samr", "wkssvc", "browser", "lsarpc")
    Set-ItemProperty -Path $regPath -Name "NullSessionPipes" -Value $pipes -Type MultiString
    Write-Host "[+] Null session pipes configured: $($pipes -join ', ')" -ForegroundColor Green

    # Allow null session shares
    Set-ItemProperty -Path $regPath -Name "NullSessionShares" -Value @("IPC`$") -Type MultiString
    Write-Host "[+] IPC$ added to null session shares" -ForegroundColor Green

    Write-Host ""
    Write-Host "    Attack: smbclient -N //10.10.10.100/IPC$"
    Write-Host "            enum4linux -a 10.10.10.100"
} catch {
    Write-Host "[!] Failed to configure null sessions: $_" -ForegroundColor Red
}
