[CmdletBinding()]
param(
    [string]$PayloadPath = '',
    [string]$OfflineFixtureRoot = ''
)

$ErrorActionPreference = 'Stop'

$commonModulePath = Join-Path $PSScriptRoot 'FusionManagedUpdate.Common.psm1'
$action1ModulePath = Join-Path $PSScriptRoot 'Action1Repository.psm1'
Import-Module $commonModulePath -Force
Import-Module $action1ModulePath -Force

if (-not $PayloadPath) {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $PayloadPath = Join-Path (Join-Path $repoRoot 'dist') 'FusionManagedUpdater.ps1'
}
if (-not (Test-Path -LiteralPath $PayloadPath)) {
    throw "Action1 payload was not found: $PayloadPath"
}

function Read-OfflineJson {
    param([Parameter(Mandatory = $true)][string]$Name)
    $path = Join-Path $OfflineFixtureRoot $Name
    if (-not (Test-Path -LiteralPath $path)) { throw "Offline fixture file was not found: $path" }
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}

function Test-OfflineJson {
    param([Parameter(Mandatory = $true)][string]$Name)
    return Test-Path -LiteralPath (Join-Path $OfflineFixtureRoot $Name)
}

function Write-OfflineRequest {
    param([string]$Line)
    Add-Content -LiteralPath (Join-Path $OfflineFixtureRoot 'api-requests.log') -Encoding ASCII -Value $Line
}

$config = Get-FusionContainerRuntimeConfig

if ($OfflineFixtureRoot) {
    $accessToken = (Read-OfflineJson -Name 'token.json').access_token
    $requestCommand = {
        param($Method, $Path, $Body)
        Write-OfflineRequest -Line "$Method $Path"
        if ($Method -eq 'GET' -and $Path -like '/software-repository/*?custom=yes*') { return Read-OfflineJson -Name 'packages.json' }
        if ($Method -eq 'POST' -and $Path -eq "/software-repository/$($config.Action1OrgId)") { return [pscustomobject]@{ id = 'pkg-created'; name = $Body.name } }
        throw "Offline request is not defined: $Method $Path"
    }
}
else {
    $accessToken = Get-Action1AccessToken -BaseUrl $config.Action1BaseUrl -ClientId $config.Action1ClientId -ClientSecret $config.Action1ClientSecret
    $requestCommand = $null
}

$package = Ensure-Action1PackageByName -BaseUrl $config.Action1BaseUrl -OrgId $config.Action1OrgId -AccessToken $accessToken -PackageName $config.PackageName -RequestCommand $requestCommand

if ($OfflineFixtureRoot) {
    $inventory = Read-OfflineJson -Name 'installed-software.json'
    $packageDetails = Read-OfflineJson -Name 'package.json'
}
else {
    $inventoryFilter = [uri]::EscapeDataString('Autodesk Fusion')
    $inventory = Invoke-Action1JsonApi -Method 'GET' -BaseUrl $config.Action1BaseUrl -AccessToken $accessToken -Path "/installed-software/$($config.Action1OrgId)/data?filter=$inventoryFilter&limit=1000"
    $packageDetails = Invoke-Action1JsonApi -Method 'GET' -BaseUrl $config.Action1BaseUrl -AccessToken $accessToken -Path "/software-repository/$($config.Action1OrgId)/$($package.id)?fields=versions"
}

try {
    $buildVersion = Resolve-FusionWatcherBuildVersion -Inventory $inventory
}
catch {
    if ($_.Exception.Message -like '*Action1 installed software inventory did not report*') {
        throw 'Action1 installed software inventory did not report an Autodesk Fusion build version for stateless repository sync. Refresh Action1 inventory before running repository sync.'
    }
    throw
}
$syncAction = Resolve-Action1VersionSyncAction -Package $packageDetails -BuildVersion $buildVersion

if ($syncAction -eq 'NoOp') {
    Write-Host "Action1 Fusion history version for $buildVersion is already recorded with an uploaded payload."
    exit 0
}

$existingRecord = $null
$versionId = $null
if ($syncAction -eq 'UploadMissingBinary') {
    $existingRecord = Get-Action1PackageVersionRecord -Package $packageDetails -BuildVersion $buildVersion
    $versionId = $existingRecord.id
    if ([string]::IsNullOrWhiteSpace([string]$versionId)) {
        throw "Action1 package version record for Fusion build $buildVersion did not include an id."
    }

    $versionDetail = $null
    if ($OfflineFixtureRoot) {
        if (Test-OfflineJson -Name 'version-detail.json') {
            $versionDetail = Read-OfflineJson -Name 'version-detail.json'
        }
    }
    else {
        $versionDetail = Invoke-Action1JsonApi -Method 'GET' -BaseUrl $config.Action1BaseUrl -AccessToken $accessToken -Path "/software-repository/$($config.Action1OrgId)/$($package.id)/versions/$versionId"
    }

    if ($null -ne $versionDetail -and (Test-Action1PackageVersionHasWindowsBinary -VersionRecord $versionDetail)) {
        Write-Host "Action1 Fusion history version for $buildVersion is already recorded with an uploaded payload."
        exit 0
    }
}

if ($syncAction -eq 'CreateAndUpload') {
    $body = New-Action1FusionVersionBody -BuildVersion $buildVersion -DetectedDate (Get-Date).ToString('yyyy-MM-dd') -PayloadFileName 'FusionManagedUpdater.ps1'
    if ($OfflineFixtureRoot) {
        Write-OfflineRequest -Line "POST /software-repository/$($config.Action1OrgId)/$($package.id)/versions"
        if (Test-OfflineJson -Name 'created-version-response.json') {
            $createdVersion = Read-OfflineJson -Name 'created-version-response.json'
        }
        else {
            $createdVersion = [pscustomobject]@{ id = "$($buildVersion)_offline"; version = $buildVersion }
        }
    }
    else {
        $createdVersion = New-Action1RepositoryVersion -BaseUrl $config.Action1BaseUrl -OrgId $config.Action1OrgId -PackageId $package.id -AccessToken $accessToken -Body $body
    }
    $versionId = $createdVersion.id
    if ([string]::IsNullOrWhiteSpace([string]$versionId)) {
        throw "Action1 create version response for Fusion build $buildVersion did not include an id."
    }
}
else {
    if ([string]::IsNullOrWhiteSpace([string]$versionId)) {
        throw "Action1 package version record for Fusion build $buildVersion did not include an id."
    }
}

if ($OfflineFixtureRoot) {
    Write-OfflineRequest -Line "UPLOAD /software-repository/$($config.Action1OrgId)/$($package.id)/versions/$versionId/upload"
}
else {
    Send-Action1VersionPayload -BaseUrl $config.Action1BaseUrl -OrgId $config.Action1OrgId -PackageId $package.id -VersionId $versionId -AccessToken $accessToken -PayloadPath $PayloadPath
    $confirmedVersion = Invoke-Action1JsonApi -Method 'GET' -BaseUrl $config.Action1BaseUrl -AccessToken $accessToken -Path "/software-repository/$($config.Action1OrgId)/$($package.id)/versions/$versionId"
    if (-not (Test-Action1PackageVersionHasWindowsBinary -VersionRecord $confirmedVersion)) {
        throw "Action1 version $versionId did not report binary_id.Windows_64 after upload."
    }
}

if ($syncAction -eq 'UploadMissingBinary') {
    Write-Host "Uploaded missing Action1 payload for Fusion history version $buildVersion."
}
else {
    Write-Host "Created Action1 Fusion history version for $buildVersion and uploaded payload."
}
