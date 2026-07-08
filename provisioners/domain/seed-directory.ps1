param(
    [string[]]
    [Parameter(Position=0, ValueFromRemainingArguments)]
    $files
)
#This script will take JSON input for new AD objects and will create them. Support for the following objects is currently available:
# * OUs
# * Groups
# * AD Users
# ** Name
# ** Department
# ** Title
# ** SPN Bit
# * Group Members

. C:\vagrant\provisioners\get-lab-config.ps1
Import-Module C:\vagrant\provisioners\phase-timer.psm1 -Force
$cfg    = Get-LabConfig
$domain = $cfg.domain

Start-PhaseTimer -PhaseName "CREATE AD OBJECTS (OUs, groups, users)"

try {
    Import-Module ActiveDirectory -ErrorAction Stop
} catch {
    throw "Module ActiveDirectory not Installed"
}

# Wait for AD Web Services (ADWS, port 9389) to answer instead of a blind sleep.
# The ActiveDirectory cmdlets need ADWS, which comes up slowly after the forest
# install + reboot. Poll Get-ADDomain until it responds, with a hard timeout.
$deadline = (Get-Date).AddMinutes(6)
while ($true) {
    try {
        Get-ADDomain -ErrorAction Stop | Out-Null
        break
    } catch {
        if ((Get-Date) -ge $deadline) {
            throw "AD Web Services not ready after 6 minutes: $_"
        }
        Start-Sleep -Seconds 10
    }
}

foreach ($file in $files) {
    $objects = Get-Content -Raw -Path "C:\vagrant\inventory\${file}" | ConvertFrom-Json
    foreach ($object in $objects.objects) {
        $path = $object.path + $domain.dn

        if ($object.type -eq "ou") {
            $name = $object.name
            $ou = Get-ADOrganizationalUnit -Filter { name -eq $name }
            if ($ou -and $ou.distinguishedname.EndsWith($name + "," + $path)) {
                echo "${name} already exists."
                continue
            }

            New-ADOrganizationalUnit -Name $object.name -Path $path
        } elseif ($object.type -eq "group") {
            $name = $object.name
            if ([bool] (Get-ADGroup -Filter { samAccountName -eq $name })) {
                echo "${name} already exists."
                continue
            }

            New-ADGroup `
                -Name $object.name `
                -SamAccountName $object.name `
                -DisplayName $object.name `
                -Path $path `
                -GroupScope Global
        } elseif ($object.type -eq "user") {
            $username = $object.username
            if ([bool] (Get-ADUser -Filter { samAccountName -eq $username })) {
                echo "${username} already exists."
                continue
            }

            $optional = @{}
            if ($object | Get-Member first) {
                $optional['GivenName'] = $object.first
                $optional['Surname'] = $object.last
                $optional['DisplayName'] = $object.first + " " + $object.last
            }

            if ($object | Get-Member department) {
                $optional['Department'] = $object.department
            }

            if ($object | Get-Member title) {
                $optional['Title'] = $object.title
            }            

            if ($object | Get-Member description) {
                $optional['Description'] = $object.description
            }

            if ($object | Get-Member spn) {
                # SPNs in lab-users.json are already fully qualified; register as-is.
                $optional['ServicePrincipalNames'] = @($object.spn)
            }

            $password = ConvertTo-SecureString $object.password -AsPlaintext -Force

            New-ADUser `
                -Name $object.username `
                -SamAccountName $object.username `
                -Path $path `
                -Enabled $true `
                -AccountPassword $password `
                @optional

            Write-Host "[OK] Created user $($object.username)"

            if ($object | Get-Member groups) {
                foreach ($group in $object.groups) {
                    Add-ADGroupMember -Identity $group -Members $object.username
                }
            }
        } else {
            echo "Unknown object type."
        }
    }
}

Stop-PhaseTimer -Status Success
Show-InstallationSummary
