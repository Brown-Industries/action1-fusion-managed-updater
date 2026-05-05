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
$payloadFileName = New-Action1PayloadFileName -PayloadPath $PayloadPath

function Get-Timestamp {
    return [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Write-Log {
    param([Parameter(Mandatory = $true)][string]$Message)
    # [Console]::Out.WriteLine + Flush is robust against PowerShell-in-Docker where
    # Write-Host can silently drop output when no TTY is attached.
    [Console]::Out.WriteLine("[$(Get-Timestamp)] $Message")
    [Console]::Out.Flush()
}

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Name, [string]$Detail = '')
    $body = if ([string]::IsNullOrWhiteSpace($Detail)) { "FUSION_STEP $Name" } else { "FUSION_STEP $Name $Detail" }
    Write-Log $body
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
Write-Step 'sync_start' "package=$($config.PackageName) org=$($config.Action1OrgId)"

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
    Write-Step 'action1_token_acquire'
    $accessToken = Get-Action1AccessToken -BaseUrl $config.Action1BaseUrl -ClientId $config.Action1ClientId -ClientSecret $config.Action1ClientSecret
    $requestCommand = $null
}

$package = Resolve-Action1PackageByName -BaseUrl $config.Action1BaseUrl -OrgId $config.Action1OrgId -AccessToken $accessToken -PackageName $config.PackageName -RequestCommand $requestCommand
Write-Step 'action1_package_resolved' "id=$($package.id) name=$($package.name)"

if ($OfflineFixtureRoot) {
    $inventory = Read-OfflineJson -Name 'installed-software.json'
    $packageDetails = Read-OfflineJson -Name 'package.json'
}
else {
    Write-Step 'inventory_query_start'
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
Write-Step 'inventory_build_resolved' "build=$buildVersion"
$syncAction = Resolve-Action1VersionSyncAction -Package $packageDetails -BuildVersion $buildVersion -PayloadFileName $payloadFileName
Write-Step 'sync_action_resolved' "action=$syncAction build=$buildVersion"

if ($syncAction -eq 'NoOp') {
    Write-Step 'noop' "build=$buildVersion already recorded with payload $payloadFileName"
    Write-Log "Action1 Fusion history version for $buildVersion is already recorded with an uploaded payload."
    exit 0
}

$existingRecord = $null
$versionId = $null
if ($syncAction -in @('UploadMissingBinary', 'UploadCurrentPayload')) {
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

    if ($null -ne $versionDetail -and
        (Test-Action1PackageVersionHasWindowsBinary -VersionRecord $versionDetail) -and
        (Test-Action1PackageVersionUsesPayloadFileName -VersionRecord $versionDetail -PayloadFileName $payloadFileName)) {
        Write-Step 'noop' "build=$buildVersion already recorded with payload $payloadFileName"
        Write-Log "Action1 Fusion history version for $buildVersion is already recorded with an uploaded payload."
        exit 0
    }
}

if ($syncAction -eq 'CreateAndUpload') {
    $body = New-Action1FusionVersionBody -BuildVersion $buildVersion -DetectedDate (Get-Date).ToString('yyyy-MM-dd') -PayloadFileName $payloadFileName
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
    Write-Step 'action1_version_create' "id=$versionId build=$buildVersion"
}
else {
    if ([string]::IsNullOrWhiteSpace([string]$versionId)) {
        throw "Action1 package version record for Fusion build $buildVersion did not include an id."
    }
    if ($OfflineFixtureRoot) {
        Write-OfflineRequest -Line "PATCH /software-repository/$($config.Action1OrgId)/$($package.id)/versions/$versionId"
    }
    else {
        [void](Set-Action1RepositoryVersionPayloadFileName -BaseUrl $config.Action1BaseUrl -OrgId $config.Action1OrgId -PackageId $package.id -VersionId $versionId -AccessToken $accessToken -PayloadFileName $payloadFileName)
    }
    Write-Step 'action1_version_existing' "id=$versionId build=$buildVersion"
}

Write-Step 'payload_upload_start' "version_id=$versionId payload=$payloadFileName"
if ($OfflineFixtureRoot) {
    Write-OfflineRequest -Line "UPLOAD /software-repository/$($config.Action1OrgId)/$($package.id)/versions/$versionId/upload"
}
else {
    Send-Action1VersionPayload -BaseUrl $config.Action1BaseUrl -OrgId $config.Action1OrgId -PackageId $package.id -VersionId $versionId -AccessToken $accessToken -PayloadPath $PayloadPath
    $confirmedVersion = Invoke-Action1JsonApi -Method 'GET' -BaseUrl $config.Action1BaseUrl -AccessToken $accessToken -Path "/software-repository/$($config.Action1OrgId)/$($package.id)/versions/$versionId"
    if (-not (Test-Action1PackageVersionHasWindowsBinary -VersionRecord $confirmedVersion)) {
        throw "Action1 version $versionId did not report binary_id.Windows_64 after upload."
    }
    if (-not (Test-Action1PackageVersionUsesPayloadFileName -VersionRecord $confirmedVersion -PayloadFileName $payloadFileName)) {
        throw "Action1 version $versionId did not report expected Windows payload file name '$payloadFileName' after upload."
    }
}
Write-Step 'verification_success' "version_id=$versionId build=$buildVersion"

if ($syncAction -eq 'UploadMissingBinary') {
    Write-Log "Uploaded missing Action1 payload for Fusion history version $buildVersion."
}
elseif ($syncAction -eq 'UploadCurrentPayload') {
    Write-Log "Uploaded current Action1 payload for Fusion history version $buildVersion."
}
else {
    Write-Log "Created Action1 Fusion history version for $buildVersion and uploaded payload."
}
