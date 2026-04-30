$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$testFile = Join-Path $PSScriptRoot 'FusionManagedUpdate.Tests.ps1'

$script:Failures = 0

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)] $Actual,
        [Parameter(Mandatory = $true)] $Expected,
        [Parameter(Mandatory = $true)] [string] $Message
    )
    if ($Actual -ne $Expected) {
        $script:Failures++
        Write-Host "FAIL: $Message" -ForegroundColor Red
        Write-Host "  Expected: $Expected"
        Write-Host "  Actual:   $Actual"
    } else {
        Write-Host "PASS: $Message" -ForegroundColor Green
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)] [bool] $Condition,
        [Parameter(Mandatory = $true)] [string] $Message
    )
    if (-not $Condition) {
        $script:Failures++
        Write-Host "FAIL: $Message" -ForegroundColor Red
    } else {
        Write-Host "PASS: $Message" -ForegroundColor Green
    }
}

. $testFile

if ($script:Failures -gt 0) {
    Write-Host "$script:Failures test failure(s)." -ForegroundColor Red
    exit 1
}

Write-Host 'All tests passed.' -ForegroundColor Green
exit 0
