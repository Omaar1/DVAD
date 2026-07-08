# lint-scripts.ps1 - enforce the lab's script conventions:
#   1. every first-party .ps1/.psm1 filename is kebab-case (lowercase, digits, single hyphens)
#   2. no non-ASCII bytes in .ps1/.psm1 (PS 5.1 + CP1252 mangles smart quotes / em-dashes,
#      which breaks parsing - keep code strictly ASCII)
#
# Exit 0 = clean, 1 = violations. Run from anywhere:
#   pwsh tools/lint-scripts.ps1
#
# Vendored / third-party trees are exempt (we do not control their naming or encoding).

[CmdletBinding()]
param([string]$Root = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'

$excluded = @(
    '\provisioners\vulns\',
    '\provisioners\services\ADCS\ADCSTemplate\',
    '\provisioners\services\SCCM\MECM_Setup\'
)

$kebab = '^[a-z0-9]+(-[a-z0-9]+)*\.(ps1|psm1)$'

$files = Get-ChildItem -Path $Root -Recurse -File |
    Where-Object { $_.Extension -in '.ps1', '.psm1' } |
    Where-Object {
        $full = $_.FullName
        $skip = $false
        foreach ($ex in $excluded) { if ($full -like "*$ex*") { $skip = $true; break } }
        -not $skip
    }

$violations = @()
foreach ($f in $files) {
    if ($f.Name -cnotmatch $kebab) {
        $violations += "NAME   $($f.FullName) -> filename is not kebab-case"
    }
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    foreach ($b in $bytes) {
        if ($b -gt 127) {
            $violations += "ASCII  $($f.FullName) -> contains a non-ASCII byte"
            break
        }
    }
}

if ($violations.Count -gt 0) {
    Write-Host "[FAIL] lint-scripts: $($violations.Count) violation(s):" -ForegroundColor Red
    $violations | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}

Write-Host "[OK] lint-scripts: $($files.Count) first-party script(s) clean (kebab-case + ASCII)." -ForegroundColor Green
exit 0
