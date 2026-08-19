# deps.psm1 - host-side payload cache for the DVAD lab.
#
# Reads inventory/lab-deps.json and makes sure every payload the selected
# profile needs exists under cache/ BEFORE any VM is started. Downloading on the
# host (rather than inside each guest) is deliberate: cache/ is the repo root,
# which Vagrant mounts into every guest as C:\vagrant, so the bytes survive
# `vagrant destroy` and a failed provision never re-downloads.
#
# Resolution order for a payload is cache -> legacy in-repo path. That keeps
# existing working copies (which still carry the committed binaries) building
# while a fresh clone fetches into cache/ instead.

Set-StrictMode -Version Latest

function Get-LabRepoRoot {
    return (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
}

function Get-LabDeps {
    <#
    .SYNOPSIS
        Loads the payload manifest, optionally filtered to one profile.
    #>
    [CmdletBinding()]
    param(
        [Alias('Profile')]
        [string] $ProfileName
    )

    $path = Join-Path (Get-LabRepoRoot) 'inventory\lab-deps.json'
    if (-not (Test-Path $path)) { throw "lab-deps.json not found at $path" }

    $deps = (Get-Content -Raw $path | ConvertFrom-Json).deps
    # No comma-wrap here: callers pipe this, and wrapping an empty result would
    # yield a phantom element that downstream code mistakes for a dep object.
    if ($ProfileName) { $deps = @($deps | Where-Object { $_.profiles -contains $ProfileName }) }
    return @($deps)
}

function Get-LabDepPath {
    <#
    .SYNOPSIS
        Resolves where a payload actually is: cache first, then the legacy path.
    .OUTPUTS
        The resolved absolute path, or $null when the payload is absent.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Dep)

    $root = Get-LabRepoRoot

    foreach ($rel in @($Dep.dest, $Dep.legacyPath)) {
        if (-not $rel) { continue }
        $full = Join-Path $root ($rel -replace '/', '\')
        if ($rel.EndsWith('/') -or $rel.EndsWith('\')) {
            # Directory payload: present when it exists and is non-empty.
            if ((Test-Path $full -PathType Container) -and
                @(Get-ChildItem $full -File -ErrorAction SilentlyContinue).Count -gt 0) {
                return $full
            }
        } elseif (Test-Path $full -PathType Leaf) {
            return $full
        }
    }
    return $null
}

function Test-LabDep {
    <#
    .SYNOPSIS
        Reports the state of one payload: present, hash-verified, and from where.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Dep)

    $root  = Get-LabRepoRoot
    $found = Get-LabDepPath -Dep $Dep

    $cacheFull = Join-Path $root ($Dep.dest -replace '/', '\')

    # "Staged" means it resolved via 'dest' - the location this payload is
    # SUPPOSED to live in, which is not always under cache/ (the SCCM media
    # deliberately stays where install-mecm.ps1 anchors its tree). "Legacy"
    # means it only resolved via the old in-repo path and will relocate on a
    # re-fetch. Comparing against dest, not against the literal "cache" prefix,
    # is what keeps that distinction honest.
    $isStaged = $found -and ($found.TrimEnd('\') -ieq $cacheFull.TrimEnd('\'))

    $status = 'Missing'
    $note   = ''

    if ($found) {
        $status = if ($isStaged) { 'Staged' } else { 'Legacy' }
        if (-not $isStaged) { $note = 'in-repo copy; will move on re-fetch' }

        # Hash check only applies to single-file payloads with a pinned hash.
        if ($Dep.sha256 -and (Test-Path $found -PathType Leaf)) {
            $actual = (Get-FileHash -Path $found -Algorithm SHA256).Hash
            if ($actual -ne $Dep.sha256.ToUpper()) {
                $status = 'Corrupt'
                $note   = "sha256 mismatch (expected $($Dep.sha256.Substring(0,12))..., got $($actual.Substring(0,12))...)"
            } else {
                $note = 'sha256 verified'
            }
        } elseif (Test-Path $found -PathType Leaf) {
            $note = if ($note) { $note } else { 'not pinned' }
        }
    }

    [PSCustomObject]@{
        Id      = $Dep.id
        Status  = $status
        Path    = $found
        Target  = $cacheFull
        Source  = $Dep.source
        Note    = $note
        Dep     = $Dep
    }
}

function Invoke-LabDownload {
    <#
    .SYNOPSIS
        Downloads a URL to a destination, preferring BITS for large files.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] [string] $Destination
    )

    $dir = Split-Path -Parent $Destination
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    # Download to a .part file so an interrupted transfer never looks complete.
    $part = "$Destination.part"
    if (Test-Path $part) { Remove-Item $part -Force }

    try {
        Start-BitsTransfer -Source $Url -Destination $part -ErrorAction Stop
    } catch {
        Write-Host "      BITS failed, falling back to Invoke-WebRequest..." -ForegroundColor DarkYellow
        $prev = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'   # progress bar makes IWR far slower
        try {
            Invoke-WebRequest -Uri $Url -OutFile $part -UseBasicParsing -TimeoutSec 3600 -ErrorAction Stop
        } finally {
            $ProgressPreference = $prev
        }
    }

    if (-not (Test-Path $part)) { throw "Download produced no file: $Url" }
    Move-Item -Path $part -Destination $Destination -Force
    return $Destination
}

function Install-LabDep {
    <#
    .SYNOPSIS
        Ensures one payload is present in cache/, fetching it if needed.
    .PARAMETER Force
        Re-fetch even when the payload already resolves.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Dep,
        [switch] $Force
    )

    $root  = Get-LabRepoRoot
    $state = Test-LabDep -Dep $Dep

    if ($state.Status -in @('Staged', 'Legacy') -and -not $Force) {
        return $state
    }

    $dest = Join-Path $root ($Dep.dest -replace '/', '\')

    switch ($Dep.source) {

        'download' {
            Write-Host "    fetching $($Dep.id) ..." -ForegroundColor Cyan
            if ($Dep.PSObject.Properties.Name -contains 'archive' -and $Dep.archive -eq 'zip') {
                # Download the archive to a temp file, pull out just the member we want.
                $tmp = Join-Path $env:TEMP "dvad-$($Dep.id).zip"
                Invoke-LabDownload -Url $Dep.url -Destination $tmp | Out-Null

                $destDir = Split-Path -Parent $dest
                if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $zip = [System.IO.Compression.ZipFile]::OpenRead($tmp)
                try {
                    $entry = $zip.Entries | Where-Object { $_.Name -eq $Dep.archiveMember } | Select-Object -First 1
                    if (-not $entry) { throw "'$($Dep.archiveMember)' not found inside $($Dep.url)" }
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
                } finally {
                    $zip.Dispose()
                    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
                }
            } else {
                Invoke-LabDownload -Url $Dep.url -Destination $dest | Out-Null
            }
        }

        'media' {
            # Copy specific members out of an already-cached payload.
            $from = Join-Path $root ($Dep.mediaFrom -replace '/', '\')
            if (-not (Test-Path $from)) {
                Write-Host "    $($Dep.id): source media not extracted yet ($($Dep.mediaFrom))" -ForegroundColor Yellow
                return (Test-LabDep -Dep $Dep)
            }
            if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }

            # Anchor every member to the SAME directory as the first one. Media
            # trees like MECM's SMSSETUP\BIN often ship both x86 (I386) and x64
            # copies of the same DLL name; an independent recursive search per
            # file can silently pair an x64 exe with an x86 DLL (0xC000007B at
            # run time). The members of one dep are assumed to ship co-located.
            $anchorName = $Dep.mediaMembers[0]
            $anchorHit  = Get-ChildItem -Path $from -Filter $anchorName -Recurse -File -ErrorAction SilentlyContinue |
                          Select-Object -First 1
            if (-not $anchorHit) {
                Write-Host "      [warn] '$anchorName' not found under $($Dep.mediaFrom)" -ForegroundColor Yellow
            } else {
                $anchorDir = $anchorHit.Directory.FullName
                foreach ($m in $Dep.mediaMembers) {
                    $hit = Get-ChildItem -Path $anchorDir -Filter $m -File -ErrorAction SilentlyContinue |
                           Select-Object -First 1
                    if ($hit) {
                        Copy-Item $hit.FullName -Destination (Join-Path $dest $m) -Force
                    } else {
                        Write-Host "      [warn] '$m' not found alongside '$anchorName' in $anchorDir" -ForegroundColor Yellow
                    }
                }
            }
        }

        'manual' {
            Write-Host "    $($Dep.id): needs a one-time manual download" -ForegroundColor Yellow
            if ($Dep.PSObject.Properties.Name -contains 'howto') {
                Write-Host "      $($Dep.howto)" -ForegroundColor DarkGray
            }
            if ($Dep.url) { Write-Host "      $($Dep.url)" -ForegroundColor DarkGray }
        }

        default { throw "Unknown source '$($Dep.source)' for dep '$($Dep.id)'" }
    }

    return (Test-LabDep -Dep $Dep)
}

function Invoke-LabDepsFetch {
    <#
    .SYNOPSIS
        Ensures every payload for a profile is cached. Returns the states.
    #>
    [CmdletBinding()]
    param(
        [Alias('Profile')]
        [string] $ProfileName,
        [switch] $Force,
        [switch] $Pin
    )

    $deps   = Get-LabDeps -ProfileName $ProfileName
    $states = @()

    Write-Host ""
    Write-Host "  Payload cache (profile: $(if ($ProfileName) { $ProfileName } else { 'all' }))" -ForegroundColor Cyan
    Write-Host "  ------------------------------------------------------------" -ForegroundColor DarkGray

    foreach ($d in $deps) {
        $states += Install-LabDep -Dep $d -Force:$Force
    }

    if ($Pin) {
        Update-LabDepHash -States $states
        # Re-test after pinning: the states above were computed before the hashes
        # were written, so they would still report "not pinned".
        $states = @(Get-LabDeps -ProfileName $ProfileName | ForEach-Object { Test-LabDep -Dep $_ })
    }

    Show-LabDeps -States $states
    return $states
}

function Update-LabDepHash {
    <#
    .SYNOPSIS
        Records the observed SHA256 of each present single-file payload back into
        the manifest, so later fetches are verified.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] $States)

    $path     = Join-Path (Get-LabRepoRoot) 'inventory\lab-deps.json'
    $manifest = Get-Content -Raw $path | ConvertFrom-Json
    $changed  = 0

    foreach ($s in $States) {
        if (-not $s.Path) { continue }
        if (-not (Test-Path $s.Path -PathType Leaf)) { continue }
        $hash  = (Get-FileHash -Path $s.Path -Algorithm SHA256).Hash
        $entry = $manifest.deps | Where-Object { $_.id -eq $s.Id } | Select-Object -First 1
        if ($entry -and $entry.sha256 -ne $hash) {
            $entry.sha256 = $hash
            $changed++
            Write-Host "      pinned $($s.Id) -> $($hash.Substring(0,16))..." -ForegroundColor DarkGray
        }
    }

    if ($changed -gt 0) {
        $manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8
        Write-Host "    Pinned $changed hash(es) into inventory/lab-deps.json" -ForegroundColor Green
    }
}

function Show-LabDeps {
    <#
    .SYNOPSIS
        Prints payload states and returns $true when nothing is missing/corrupt.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] $States)

    foreach ($s in $States) {
        $glyph, $colour = switch ($s.Status) {
            'Staged'  { '[ok]  ', 'Green' }
            'Legacy'  { '[ok]  ', 'DarkYellow' }
            'Missing' { '[--]  ', 'Yellow' }
            'Corrupt' { '[FAIL]', 'Red' }
        }
        Write-Host ("  {0} {1,-12} {2,-8} {3}" -f $glyph, $s.Id, $s.Status, $s.Note) -ForegroundColor $colour
    }

    $bad = @($States | Where-Object { $_.Status -in @('Missing', 'Corrupt') })
    Write-Host "  ------------------------------------------------------------" -ForegroundColor DarkGray
    if ($bad.Count -gt 0) {
        Write-Host "  $($bad.Count) payload(s) still needed: $(($bad | ForEach-Object { $_.Id }) -join ', ')" -ForegroundColor Yellow
        Write-Host "  Provisioning can still start; each installer will fetch its own if it can." -ForegroundColor DarkGray
        Write-Host ""
        return $false
    }
    Write-Host "  All payloads for this profile are staged." -ForegroundColor Green
    Write-Host ""
    return $true
}

Export-ModuleMember -Function `
    Get-LabRepoRoot, Get-LabDeps, Get-LabDepPath, Test-LabDep, `
    Invoke-LabDownload, Install-LabDep, Invoke-LabDepsFetch, `
    Update-LabDepHash, Show-LabDeps
