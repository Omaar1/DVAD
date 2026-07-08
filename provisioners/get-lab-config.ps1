# get-lab-config.ps1
# ------------------------------------------------------------------------------
# Single source of truth loader. Dot-source this file, then call Get-LabConfig
# to get the parsed lab-config.json object:
#
#   . C:\vagrant\provisioners\get-lab-config.ps1
#   $cfg = Get-LabConfig
#   $cfg.domain.netbiosName     # "DVAD"
#   $cfg.hosts.sccm.ip          # "10.10.10.104"
#
# Resolves the config relative to this file (works both inside the VMs under
# C:\vagrant and on the host repo), or from an explicit -Path.
# ------------------------------------------------------------------------------

function Get-LabConfig {
    param([string] $Path)

    $candidates = @(
        (Join-Path $PSScriptRoot '..\inventory\lab-config.json'),
        'C:\vagrant\inventory\lab-config.json'
    )
    if (-not $Path) {
        foreach ($c in $candidates) {
            if (Test-Path $c) { $Path = $c; break }
        }
    }
    if (-not $Path -or -not (Test-Path $Path)) {
        throw "lab-config.json not found (looked in: $($candidates -join '; '))"
    }

    return (Get-Content -Raw -Path $Path | ConvertFrom-Json)
}
