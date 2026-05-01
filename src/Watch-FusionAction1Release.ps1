[CmdletBinding()]
param(
    [string]$AutodeskInstallerUrl = 'https://dl.appstreaming.autodesk.com/production/installers/Fusion%20Admin%20Install.exe',
    [string]$StatePath = '',
    [string]$PackageId = $env:ACTION1_FUSION_PACKAGE_ID,
    [string]$OrgId = $(if ($env:ACTION1_ORG_ID) { $env:ACTION1_ORG_ID } else { 'all' }),
    [string]$OfflineFixtureRoot = '',
    [switch]$AllowManualObservedBuild,
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

function Read-OfflineFixture {
    param([Parameter(Mandatory = $true)][string]$Name)

    $path = Join-Path $OfflineFixtureRoot $Name
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Offline fixture file was not found: $path"
    }
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}

function Write-OfflineFixtureRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $logPath = Join-Path $OfflineFixtureRoot 'api-requests.log'
    Add-Content -LiteralPath $logPath -Encoding ASCII -Value "$Method $Path"
}

function Invoke-Action1Api {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST', 'PATCH')][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        [object]$Body
    )
    if ($OfflineFixtureRoot) {
        Write-OfflineFixtureRequest -Method $Method -Path $Path
        if ($Method -eq 'GET' -and $Path -like '/installed-software/*') {
            return Read-OfflineFixture -Name 'action1-installed-software.json'
        }
        if ($Method -eq 'GET' -and $Path -like '/software-repository/*') {
            return Read-OfflineFixture -Name 'action1-package.json'
        }
        if ($Method -eq 'POST' -and $Path -like '/software-repository/*/versions') {
            $createdBodyPath = Join-Path $OfflineFixtureRoot 'created-version-body.json'
            $Body | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $createdBodyPath -Encoding UTF8
            return [pscustomobject]@{ id = 'offline-created-version' }
        }
        throw "Offline fixture root does not define Action1 response for $Method $Path."
    }

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
$head = if ($OfflineFixtureRoot) {
    ConvertFrom-AutodeskInstallerHeadRecord -Record (Read-OfflineFixture -Name 'autodesk-head.json')
}
else {
    Get-AutodeskInstallerHead -Url $AutodeskInstallerUrl
}
$detectedDate = (Get-Date).ToString('yyyy-MM-dd')
$manualBuildVersion = if ($env:FUSION_OBSERVED_BUILD_VERSION) { $env:FUSION_OBSERVED_BUILD_VERSION.Trim() } else { '' }
$buildVersion = if ($manualBuildVersion) { $manualBuildVersion } else { 'unknown-dry-run' }
$dryRunResult = New-FusionWatcherDryRunResult -State $state -AutodeskHead $head -BuildVersion $buildVersion -DetectedDate $detectedDate -PayloadFileName 'FusionManagedUpdater.ps1'
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

if (-not $PackageId) {
    throw 'ACTION1_FUSION_PACKAGE_ID or -PackageId is required for live version creation.'
}

if ($AllowManualObservedBuild) {
    $buildVersion = Resolve-FusionWatcherBuildVersion -Inventory ([pscustomobject]@{ items = @() }) -ManualBuildVersion $manualBuildVersion -AllowManualObservedBuild
}
else {
    $inventoryFilter = [uri]::EscapeDataString('Autodesk Fusion')
    $inventory = Invoke-Action1Api -Method GET -Path "/installed-software/$OrgId/data?filter=$inventoryFilter&limit=1000"
    $buildVersion = Resolve-FusionWatcherBuildVersion -Inventory $inventory -ManualBuildVersion $manualBuildVersion
}
$body = New-Action1FusionVersionBody -BuildVersion $buildVersion -DetectedDate $detectedDate -PayloadFileName 'FusionManagedUpdater.ps1'

$package = Invoke-Action1Api -Method GET -Path "/software-repository/$OrgId/$PackageId?fields=versions"
if (-not (Test-Action1PackageVersionContainerPresent -Package $package)) {
    throw 'Action1 package response did not include a versions container. Cannot verify duplicate package versions before live creation.'
}

[void](Assert-FusionWatcherNewBuildNotAlreadyRecorded -Package $package -BuildVersion $buildVersion)

Invoke-Action1Api -Method POST -Path "/software-repository/$OrgId/$PackageId/versions" -Body $body | Out-Null
Write-State -Path $StatePath -State $head
Write-Host "Created Action1 Fusion history version for $buildVersion."
