[CmdletBinding()]
param(
    [string]$AutodeskInstallerUrl = 'https://dl.appstreaming.autodesk.com/production/installers/Fusion%20Admin%20Install.exe',
    [string]$StatePath = '',
    [string]$PackageId = $env:ACTION1_FUSION_PACKAGE_ID,
    [string]$OrgId = $(if ($env:ACTION1_ORG_ID) { $env:ACTION1_ORG_ID } else { 'all' }),
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
if (-not $StatePath) {
    $StatePath = Join-Path $PSScriptRoot '..\state\fusion-release-state.json'
}
$modulePath = Join-Path $PSScriptRoot 'FusionManagedUpdate.Common.psm1'
Import-Module $modulePath -Force

function Read-State {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    return [pscustomobject]@{}
}

function Write-State {
    param([string]$Path, $State)
    Write-FusionWatcherState -Path $Path -State $State
}

function Invoke-Action1Api {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST', 'PATCH')][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        [object]$Body
    )
    $baseUrl = if ($env:ACTION1_BASE_URL) { $env:ACTION1_BASE_URL.TrimEnd('/') } else { 'https://app.action1.com/api/3.0' }
    $token = $env:ACTION1_ACCESS_TOKEN
    if (-not $token) {
        throw 'ACTION1_ACCESS_TOKEN is required for live Action1 API calls.'
    }
    $headers = @{ Authorization = "Bearer $token" }
    $uri = "$baseUrl/$($Path.TrimStart('/'))"
    if ($Body) {
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Depth 20)
    }
    return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
}

$state = Read-State -Path $StatePath
$head = Get-AutodeskInstallerHead -Url $AutodeskInstallerUrl
$detectedDate = (Get-Date).ToString('yyyy-MM-dd')
$buildVersion = if ($env:FUSION_OBSERVED_BUILD_VERSION) { $env:FUSION_OBSERVED_BUILD_VERSION } else { 'unknown-' + (Get-Date).ToString('yyyyMMddHHmmss') }
$dryRunResult = New-FusionWatcherDryRunResult -State $state -AutodeskHead $head -BuildVersion $buildVersion -DetectedDate $detectedDate -PayloadFileName 'FusionManagedUpdater.cmd'
$changed = $dryRunResult.Changed
$body = $dryRunResult.Action1VersionBody

if ($DryRun) {
    $dryRunResult | ConvertTo-Json -Depth 20
    exit 0
}

if (-not $changed) {
    Write-Host 'No Autodesk installer release signal changed.'
    exit 0
}

[void](Assert-FusionWatcherLiveBuildVersion -BuildVersion $buildVersion)

if (-not $PackageId) {
    throw 'ACTION1_FUSION_PACKAGE_ID or -PackageId is required for live version creation.'
}

Invoke-Action1Api -Method POST -Path "/software-repository/$OrgId/$PackageId/versions" -Body $body | Out-Null
Write-State -Path $StatePath -State $head
Write-Host "Created Action1 Fusion history version for $buildVersion."
