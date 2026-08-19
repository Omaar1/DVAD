# get-lab-payload.ps1
# ------------------------------------------------------------------------------
# Resolves a cached payload by id, for use inside the guests. Dot-source it and
# call Get-LabPayload:
#
#   . C:\vagrant\provisioners\get-lab-payload.ps1
#   $psexec = Get-LabPayload -Id psexec
#
# Lookup order is cache/ then the legacy in-repo path recorded in
# inventory/lab-deps.json. That keeps existing working copies (which still carry
# the committed binaries) building, while a fresh clone uses the host-side cache
# staged by "lab.ps1 deps".
#
# Both locations sit inside the repo, which Vagrant mounts at C:\vagrant, so
# resolving here costs nothing and never re-downloads.
# ------------------------------------------------------------------------------

function Get-LabPayloadRoot {
    # This file lives in <repo>\provisioners, so the repo root is one level up.
    $candidates = @(
        (Resolve-Path (Join-Path $PSScriptRoot '..') -ErrorAction SilentlyContinue).Path,
        'C:\vagrant'
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path (Join-Path $c 'inventory\lab-deps.json'))) { return $c }
    }
    throw "Could not locate the lab repo root (looked in: $($candidates -join '; '))"
}

function Get-LabPayload {
    <#
    .SYNOPSIS
        Returns the path to a staged payload, or $null when it is absent.
    .PARAMETER Id
        Payload id from inventory/lab-deps.json (psexec, laps, netfx3, mecm,
        extadsch, msodbcsql).
    .PARAMETER Required
        Throw a descriptive error instead of returning $null when missing.
    #>
    param(
        [Parameter(Mandatory)] [string] $Id,
        [switch] $Required
    )

    $root     = Get-LabPayloadRoot
    $manifest = Get-Content -Raw (Join-Path $root 'inventory\lab-deps.json') | ConvertFrom-Json
    $dep      = $manifest.deps | Where-Object { $_.id -eq $Id } | Select-Object -First 1

    if (-not $dep) { throw "Unknown payload id '$Id' (not in inventory/lab-deps.json)" }

    foreach ($rel in @($dep.dest, $dep.legacyPath)) {
        if (-not $rel) { continue }
        $full = Join-Path $root ($rel -replace '/', '\')

        if ($rel.EndsWith('/') -or $rel.EndsWith('\')) {
            if ((Test-Path $full -PathType Container) -and
                @(Get-ChildItem $full -File -ErrorAction SilentlyContinue).Count -gt 0) {
                return $full
            }
        } elseif (Test-Path $full -PathType Leaf) {
            return $full
        }
    }

    if ($Required) {
        $hint = if ($dep.PSObject.Properties.Name -contains 'howto') { " $($dep.howto)" } else { '' }
        throw ("Payload '$Id' ($($dep.description)) is not staged. " +
               "Expected at $($dep.dest) or $($dep.legacyPath). " +
               "Run 'lab.ps1 deps' on the host to stage it.$hint")
    }
    return $null
}
