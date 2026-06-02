. C:\vagrant\sharedscripts\Get-LabConfig.ps1
$domain = (Get-LabConfig).domain
$securePassword = ConvertTo-SecureString $domain.administratorPassword -AsPlainText -Force
$username = $domain.netbiosName + "\Administrator" 
$domainAdminCredentials = New-Object System.Management.Automation.PSCredential($username, $securePassword)

# [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
#wget "https://github.com/davidprowe/BadBlood/archive/refs/heads/master.zip"  -OutFile "badblood.zip"
#Expand-Archive .\badblood.zip -Force
Install-WindowsFeature -Name RSAT-AD-PowerShell
Import-Module -Name ActiveDirectory
# .\badblood\BadBlood-master\Invoke-BadBlood.ps1  -NonInteractive -UserCount 100 -GroupCount 15 -ComputerCount 50 -Verbose

# Specify the path to the script and the arguments to pass
$scriptPath = ".\install-adcs.ps1"
$scriptArgs =  ""

# Use a script block to import the module and run the script with arguments
$scriptBlock = {
    Import-Module -Name ActiveDirectory
    Get-addomain
    & "$using:scriptPath" $using:scriptArgs
}

# Run the script as another user
Start-Process -FilePath "powershell.exe" `
    -ArgumentList "-noexit -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" $scriptArgs" `
    -Credential $domainAdminCredentials `
    -NoNewWindow -Wait