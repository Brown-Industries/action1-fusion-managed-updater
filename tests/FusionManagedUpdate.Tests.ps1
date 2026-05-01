$repoRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repoRoot 'src/FusionManagedUpdate.Common.psm1'
Import-Module $modulePath -Force

$fixtureRoot = Join-Path $PSScriptRoot 'fixtures'
$endpointScript = Join-Path $repoRoot 'src/Invoke-FusionManagedUpdate.ps1'
$watcherScript = Join-Path $repoRoot 'src/Watch-FusionAction1Release.ps1'
$payloadBuilder = Join-Path $repoRoot 'packaging/build-action1-payload.ps1'

function Get-TestPowerShellCommand {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) { return $pwsh.Source }
    return 'powershell.exe'
}

$testPowerShell = Get-TestPowerShellCommand

Assert-True (-not [string]::IsNullOrWhiteSpace($testPowerShell)) 'Test runner resolves a PowerShell executable'

function Assert-ThrowsLike {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Message
    )

    try {
        & $ScriptBlock
        Assert-True $false $Message
    }
    catch {
        Assert-True ($_.Exception.Message -like $Pattern) $Message
    }
}

function Invoke-EndpointScript {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $testPowerShell -NoProfile -ExecutionPolicy Bypass -File $endpointScript @Arguments 2>&1
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = ($output | Out-String)
    }
}

function Invoke-WatcherScript {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $testPowerShell -NoProfile -ExecutionPolicy Bypass -File $watcherScript @Arguments 2>&1
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = ($output | Out-String)
    }
}

function Invoke-PayloadBuilder {
    param([Parameter(Mandatory = $true)][string]$OutputPath)

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $testPowerShell -NoProfile -ExecutionPolicy Bypass -File $payloadBuilder -OutputPath $OutputPath 2>&1
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = ($output | Out-String)
    }
}

function Invoke-Payload {
    param(
        [Parameter(Mandatory = $true)][string]$PayloadPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $PayloadPath @Arguments 2>&1
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = ($output | Out-String)
    }
}

$parts = ConvertTo-FusionVersionParts -Version '2702.1.58'
Assert-Equal $parts[0] 2702 'Version parser reads first segment'
Assert-Equal $parts[1] 1 'Version parser reads second segment'
Assert-Equal $parts[2] 58 'Version parser reads third segment'

Assert-Equal (Compare-FusionVersion -Left '2702.1.58' -Right '2702.1.47') 1 '2702.1.58 is newer than 2702.1.47'
Assert-Equal (Compare-FusionVersion -Left '2702.1.47' -Right '2702.1.58') -1 '2702.1.47 is older than 2702.1.58'
Assert-Equal (Compare-FusionVersion -Left '2702.1.47' -Right '2702.1.47') 0 'Matching versions compare equal'

$fusionInfo = Read-FusionInfoFile -Path (Join-Path $fixtureRoot 'fusioninfo-2702.1.47.json')
Assert-Equal $fusionInfo.BuildVersion '2702.1.47' 'Fusion info parser returns build version'
Assert-Equal $fusionInfo.ReleaseVersion '20260412194756' 'Fusion info parser returns release version'
Assert-Equal $fusionInfo.DisplayName 'Autodesk Fusion' 'Fusion info parser returns display name'

$inventory = Get-Content -LiteralPath (Join-Path $fixtureRoot 'action1-installed-fusion.json') -Raw | ConvertFrom-Json
$highest = Get-HighestFusionInventoryVersion -Inventory $inventory
Assert-Equal $highest '2702.1.58' 'Highest Action1 Fusion inventory version is detected'

$inventoryWithInvalidVersion = [pscustomobject]@{
    items = @(
        [pscustomobject]@{ fields = [pscustomobject]@{ Name = 'Autodesk Fusion'; Version = '2702.bad.99' } },
        [pscustomobject]@{ fields = [pscustomobject]@{ Name = 'Autodesk Fusion'; Version = '2702.1.47' } },
        [pscustomobject]@{ fields = [pscustomobject]@{ Name = 'Autodesk Fusion 360'; Version = '2702.1.58' } }
    )
}
$highestValid = Get-HighestFusionInventoryVersion -Inventory $inventoryWithInvalidVersion
Assert-Equal $highestValid '2702.1.58' 'Highest Action1 Fusion inventory version skips invalid versions'

$autodeskHeadFixture = Get-Content -LiteralPath (Join-Path $fixtureRoot 'autodesk-head-current.json') -Raw | ConvertFrom-Json
$autodeskHead = ConvertFrom-AutodeskInstallerHeadRecord -Record $autodeskHeadFixture
Assert-Equal $autodeskHead.Url 'https://dl.appstreaming.autodesk.com/production/installers/Fusion%20Admin%20Install.exe' 'Autodesk HEAD parser returns URL'
Assert-Equal $autodeskHead.LastModified 'Thu, 23 Apr 2026 03:21:46 GMT' 'Autodesk HEAD parser returns Last-Modified'
Assert-Equal $autodeskHead.ETag '"945f8d5c5e70f2a1ffa5f7e666a72247:1776914468.464812"' 'Autodesk HEAD parser returns ETag'
Assert-Equal $autodeskHead.ContentLength '1486420912' 'Autodesk HEAD parser returns Content-Length'

$warning = New-HistoricalVersionWarning -BuildVersion '2702.1.58' -DetectedDate '2026-04-30'
Assert-True ($warning -like '*historical build*') 'Warning says historical builds are not pinned installers'
Assert-True ($warning -like '*currently available Fusion build*') 'Warning says Autodesk controls currently available build'

$versionBody = New-Action1FusionVersionBody -BuildVersion '2702.1.58' -DetectedDate '2026-04-30' -PayloadFileName 'FusionManagedUpdater.cmd'
Assert-Equal $versionBody.version '2702.1.58' 'Action1 version body uses Fusion build version'
Assert-Equal $versionBody.app_name_match '^Autodesk Fusion(?: 360)?$' 'Action1 version body matches current and legacy Fusion names'
Assert-True (-not $versionBody.Contains('description')) 'Action1 version body omits non-settable description field'
Assert-True (-not $versionBody.Contains('internal_notes')) 'Action1 version body omits non-settable internal notes field'
Assert-Equal $versionBody.silent_install_switches '' 'Action1 payload launcher needs no switches'
Assert-Equal $versionBody.success_exit_codes '0' 'Action1 success exit code is zero'

$containerConfig = Get-FusionContainerRuntimeConfig -Environment @{
    ACTION1_CLIENT_ID = 'client-id'
    ACTION1_CLIENT_SECRET = 'client-secret'
}
Assert-Equal $containerConfig.Action1ClientId 'client-id' 'Container config reads Action1 client id'
Assert-Equal $containerConfig.Action1ClientSecret 'client-secret' 'Container config reads Action1 client secret'
Assert-Equal $containerConfig.Action1BaseUrl 'https://app.action1.com/api/3.0' 'Container config defaults Action1 base URL'
Assert-Equal $containerConfig.Action1OrgId 'all' 'Container config defaults Action1 org id'
Assert-Equal $containerConfig.PackageName 'Autodesk Fusion Managed Updater' 'Container config defaults package name'
Assert-Equal $containerConfig.OneShot $true 'Container config defaults to one-shot mode'
Assert-Equal $containerConfig.CheckFrequencyMinutes 1440 'Container config defaults to daily interval'

$scheduledConfig = Get-FusionContainerRuntimeConfig -Environment @{
    ACTION1_CLIENT_ID = 'client-id'
    ACTION1_CLIENT_SECRET = 'client-secret'
    ONE_SHOT = 'false'
    CHECK_FREQUENCY_CRON = '0 */6 * * *'
    CHECK_FREQUENCY_MINUTES = '30'
}
Assert-Equal $scheduledConfig.OneShot $false 'Container config supports long-running mode'
Assert-Equal $scheduledConfig.CheckFrequencyCron '0 */6 * * *' 'Container config reads cron schedule'
Assert-Equal $scheduledConfig.CheckFrequencyMinutes 30 'Container config reads interval schedule'

Assert-ThrowsLike {
    Get-FusionContainerRuntimeConfig -Environment @{ ACTION1_CLIENT_ID = 'client-id' }
} '*ACTION1_CLIENT_SECRET*' 'Container config requires Action1 client secret'

Assert-ThrowsLike {
    Get-FusionContainerRuntimeConfig -Environment @{ ACTION1_CLIENT_SECRET = 'client-secret' }
} '*ACTION1_CLIENT_ID*' 'Container config requires Action1 client id'

$packageBody = New-Action1FusionPackageBody -PackageName 'Autodesk Fusion Managed Updater'
Assert-Equal $packageBody.name 'Autodesk Fusion Managed Updater' 'Package body uses requested package name'
Assert-Equal $packageBody.vendor 'Autodesk' 'Package body uses Autodesk vendor'
Assert-Equal $packageBody.platform 'Windows' 'Package body targets Windows'
Assert-True ($packageBody.description -like '*Historical versions are release records only*') 'Package body warns about historical records'
Assert-True ($packageBody.internal_notes -like '*Do not use this package for rollback*') 'Package body warns against rollback'

$unchangedDryRun = New-FusionWatcherDryRunResult -State $autodeskHead -AutodeskHead $autodeskHead -BuildVersion '2702.1.58' -DetectedDate '2026-04-30' -PayloadFileName 'FusionManagedUpdater.cmd'
Assert-Equal $unchangedDryRun.Changed $false 'Fusion watcher dry-run result reports unchanged installer state'
Assert-Equal $unchangedDryRun.AutodeskHead.ETag $autodeskHead.ETag 'Fusion watcher dry-run result includes Autodesk HEAD when unchanged'
Assert-Equal $unchangedDryRun.Action1VersionBody.version '2702.1.58' 'Fusion watcher dry-run result includes Action1 version body when unchanged'

Assert-Equal (Assert-FusionWatcherLiveBuildVersion -BuildVersion '2702.1.58') '2702.1.58' 'Fusion watcher live build guard accepts observed build version'
Assert-ThrowsLike { Assert-FusionWatcherLiveBuildVersion -BuildVersion '' } '*FUSION_OBSERVED_BUILD_VERSION*' 'Fusion watcher live build guard rejects missing build version'
Assert-ThrowsLike { Assert-FusionWatcherLiveBuildVersion -BuildVersion 'unknown-20260430120000' } '*FUSION_OBSERVED_BUILD_VERSION*' 'Fusion watcher live build guard rejects unknown build version'
Assert-ThrowsLike { Assert-FusionWatcherLiveBuildVersion -BuildVersion 'latest' } '*numeric dotted Fusion build version*' 'Fusion watcher live build guard rejects non-version strings'
Assert-ThrowsLike { Assert-FusionWatcherLiveBuildVersion -BuildVersion '2702.bad.99' } '*numeric dotted Fusion build version*' 'Fusion watcher live build guard rejects non-numeric version segments'
Assert-ThrowsLike { Assert-FusionWatcherLiveBuildVersion -BuildVersion '2702' } '*numeric dotted Fusion build version*' 'Fusion watcher live build guard rejects single-segment versions'

$observedBuild = Resolve-FusionWatcherBuildVersion -Inventory $inventory -ManualBuildVersion '' -AllowManualObservedBuild:$false
Assert-Equal $observedBuild '2702.1.58' 'Fusion watcher live build resolves highest Action1 inventory version'
Assert-ThrowsLike { Resolve-FusionWatcherBuildVersion -Inventory $inventory -ManualBuildVersion '2702.1.47' -AllowManualObservedBuild:$false } '*does not match highest Action1 inventory version*' 'Fusion watcher live build rejects manual version mismatch'
$manualOverrideBuild = Resolve-FusionWatcherBuildVersion -Inventory $inventory -ManualBuildVersion '2702.1.47' -AllowManualObservedBuild:$true
Assert-Equal $manualOverrideBuild '2702.1.47' 'Fusion watcher live build allows explicit manual override'

$emptyFusionInventory = [pscustomobject]@{ items = @() }
Assert-ThrowsLike { Resolve-FusionWatcherBuildVersion -Inventory $emptyFusionInventory -ManualBuildVersion '' -AllowManualObservedBuild:$false } '*Action1 installed software inventory did not report*' 'Fusion watcher live build requires Action1 inventory by default'

$packageWithVersions = [pscustomobject]@{
    versions = [pscustomobject]@{
        items = @(
            [pscustomobject]@{ version = '2702.1.47' },
            [pscustomobject]@{ version = '2702.1.58' }
        )
    }
}
$packageVersions = @(Get-Action1PackageVersionValues -Package $packageWithVersions)
Assert-Equal ($packageVersions -join ',') '2702.1.47,2702.1.58' 'Action1 package version helper reads version container'
Assert-True (Test-Action1PackageHasVersion -Package $packageWithVersions -BuildVersion '2702.1.58') 'Action1 package version helper detects existing build version'
Assert-True (-not (Test-Action1PackageHasVersion -Package $packageWithVersions -BuildVersion '2702.1.99')) 'Action1 package version helper reports missing build version'
Assert-ThrowsLike { Assert-FusionWatcherNewBuildNotAlreadyRecorded -Package $packageWithVersions -BuildVersion '2702.1.58' } '*already has Fusion version 2702.1.58*' 'Fusion watcher duplicate guard rejects changed release signal with existing inventory build'
Assert-Equal (Assert-FusionWatcherNewBuildNotAlreadyRecorded -Package $packageWithVersions -BuildVersion '2702.1.99') '2702.1.99' 'Fusion watcher duplicate guard allows new inventory build'

$watcherLiveTempRoot = Join-Path $env:TEMP ('fmu-watcher-live-test-' + [guid]::NewGuid().ToString('N'))
$watcherStatePath = Join-Path $watcherLiveTempRoot 'state.json'
$watcherPackageJson = '{"versions":{"items":[{"version":"2702.1.47"}]}}'
$previousAction1BaseUrl = $env:ACTION1_BASE_URL
$previousAction1AccessToken = $env:ACTION1_ACCESS_TOKEN
$previousAction1PackageId = $env:ACTION1_FUSION_PACKAGE_ID
$previousAction1OrgId = $env:ACTION1_ORG_ID
$previousFusionObservedBuildVersion = $env:FUSION_OBSERVED_BUILD_VERSION
try {
    New-Item -ItemType Directory -Path $watcherLiveTempRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $watcherLiveTempRoot 'autodesk-head.json') -Encoding ASCII -Value ($autodeskHead | ConvertTo-Json -Depth 10 -Compress)
    Set-Content -LiteralPath (Join-Path $watcherLiveTempRoot 'action1-installed-software.json') -Encoding ASCII -Value ($inventory | ConvertTo-Json -Depth 20 -Compress)
    Set-Content -LiteralPath (Join-Path $watcherLiveTempRoot 'action1-package.json') -Encoding ASCII -Value $watcherPackageJson

    $env:ACTION1_BASE_URL = 'https://offline-fixture.invalid'
    $env:ACTION1_ACCESS_TOKEN = 'test-token'
    $env:ACTION1_FUSION_PACKAGE_ID = 'pkg-1'
    $env:ACTION1_ORG_ID = 'all'
    Remove-Item Env:\FUSION_OBSERVED_BUILD_VERSION -ErrorAction SilentlyContinue

    $watcherResult = Invoke-WatcherScript -Arguments @('-AutodeskInstallerUrl', 'https://offline-fixture.invalid/FusionAdminInstall.exe', '-StatePath', $watcherStatePath, '-OfflineFixtureRoot', $watcherLiveTempRoot)
    Assert-Equal $watcherResult.ExitCode 0 'Fusion watcher live script resolves build from Action1 inventory without manual env version'
    Assert-True ($watcherResult.Output -like '*Created Action1 Fusion history version for 2702.1.58*') 'Fusion watcher live script creates version from inventory build'

    $watcherLogPath = Join-Path $watcherLiveTempRoot 'api-requests.log'
    $watcherRequests = if (Test-Path -LiteralPath $watcherLogPath) { @(Get-Content -LiteralPath $watcherLogPath) } else { @() }
    Assert-True (($watcherRequests -join "`n") -like '*GET /installed-software/all/data?filter=Autodesk%20Fusion&limit=1000*') 'Fusion watcher live script queries Action1 inventory before version creation'
    Assert-True (($watcherRequests -join "`n") -like '*POST /software-repository/all/pkg-1/versions*') 'Fusion watcher live script posts Action1 version after inventory resolution'

    $createdVersionPath = Join-Path $watcherLiveTempRoot 'created-version-body.json'
    Assert-True (Test-Path -LiteralPath $createdVersionPath) 'Fusion watcher live script writes offline created version body'
    if (Test-Path -LiteralPath $createdVersionPath) {
        $createdVersion = Get-Content -LiteralPath $createdVersionPath -Raw | ConvertFrom-Json
        Assert-Equal $createdVersion.version '2702.1.58' 'Fusion watcher live script posts inventory build in Action1 version body'
        Assert-True (-not $createdVersion.PSObject.Properties['internal_notes']) 'Fusion watcher live script omits non-settable internal notes field'
        Assert-True (-not $createdVersion.PSObject.Properties['description']) 'Fusion watcher live script omits non-settable description field'
    }

    Set-Content -LiteralPath (Join-Path $watcherLiveTempRoot 'action1-package.json') -Encoding ASCII -Value '{"versions":{"items":[{"version":"2702.1.58"}]}}'
    Remove-Item -LiteralPath $watcherStatePath -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $watcherLiveTempRoot 'api-requests.log') -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $createdVersionPath -ErrorAction SilentlyContinue

    $duplicateWatcherResult = Invoke-WatcherScript -Arguments @('-AutodeskInstallerUrl', 'https://offline-fixture.invalid/FusionAdminInstall.exe', '-StatePath', $watcherStatePath, '-OfflineFixtureRoot', $watcherLiveTempRoot)
    Assert-True ($duplicateWatcherResult.ExitCode -ne 0) 'Fusion watcher live script fails duplicate inventory build when release signal changed'
    Assert-True ($duplicateWatcherResult.Output -like '*already has Fusion version 2702.1.58*') 'Fusion watcher live script reports stale inventory duplicate risk'
    Assert-True (-not (Test-Path -LiteralPath $watcherStatePath)) 'Fusion watcher live script preserves state when duplicate build blocks changed release signal'
}
finally {
    if ($null -eq $previousAction1BaseUrl) { Remove-Item Env:\ACTION1_BASE_URL -ErrorAction SilentlyContinue } else { $env:ACTION1_BASE_URL = $previousAction1BaseUrl }
    if ($null -eq $previousAction1AccessToken) { Remove-Item Env:\ACTION1_ACCESS_TOKEN -ErrorAction SilentlyContinue } else { $env:ACTION1_ACCESS_TOKEN = $previousAction1AccessToken }
    if ($null -eq $previousAction1PackageId) { Remove-Item Env:\ACTION1_FUSION_PACKAGE_ID -ErrorAction SilentlyContinue } else { $env:ACTION1_FUSION_PACKAGE_ID = $previousAction1PackageId }
    if ($null -eq $previousAction1OrgId) { Remove-Item Env:\ACTION1_ORG_ID -ErrorAction SilentlyContinue } else { $env:ACTION1_ORG_ID = $previousAction1OrgId }
    if ($null -eq $previousFusionObservedBuildVersion) { Remove-Item Env:\FUSION_OBSERVED_BUILD_VERSION -ErrorAction SilentlyContinue } else { $env:FUSION_OBSERVED_BUILD_VERSION = $previousFusionObservedBuildVersion }
    if (Test-Path -LiteralPath $watcherLiveTempRoot) {
        Remove-Item -LiteralPath $watcherLiveTempRoot -Recurse -Force
    }
}

$stateTempRoot = Join-Path $env:TEMP ('fmu-state-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stateTempRoot -Force | Out-Null
Push-Location $stateTempRoot
try {
    Write-FusionWatcherState -Path 'fusion-release-state.json' -State $autodeskHead
    Assert-True (Test-Path -LiteralPath 'fusion-release-state.json') 'Fusion watcher state writer supports bare filenames'
    $writtenState = Get-Content -LiteralPath 'fusion-release-state.json' -Raw | ConvertFrom-Json
    Assert-Equal $writtenState.ETag $autodeskHead.ETag 'Fusion watcher state writer preserves state payload'
}
finally {
    Pop-Location
    Remove-Item -LiteralPath $stateTempRoot -Recurse -Force
}

$payloadTempRoot = Join-Path $env:TEMP ('fmu-payload-test-' + [guid]::NewGuid().ToString('N'))
$payloadOutput = Join-Path $payloadTempRoot 'FusionManagedUpdater.cmd'
try {
    $payloadResult = Invoke-PayloadBuilder -OutputPath $payloadOutput
    Assert-Equal $payloadResult.ExitCode 0 'Action1 payload builder exits 0'
    Assert-True (Test-Path -LiteralPath $payloadOutput) 'Action1 payload builder writes requested output path'

    $payloadBytes = [IO.File]::ReadAllBytes($payloadOutput)
    $nonAsciiByte = $payloadBytes | Where-Object { $_ -gt 127 } | Select-Object -First 1
    Assert-True ($null -eq $nonAsciiByte) 'Action1 payload is ASCII-only'
    Assert-True ($payloadBytes.Length -lt 1MB) 'Action1 payload is under 1 MB'

    $payloadText = Get-Content -LiteralPath $payloadOutput -Raw
    Assert-True ($payloadText -like '*set "moduleb64=%work%\module.b64"*') 'Action1 payload defines module base64 path'
    Assert-True ($payloadText -like '*set "scriptb64=%work%\script.b64"*') 'Action1 payload defines script base64 path'
    Assert-True ($payloadText.Contains('[Convert]::FromBase64String')) 'Action1 payload decodes embedded files'
    Assert-True ($payloadText -like '*powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ps1%" %**') 'Action1 payload forwards launcher arguments to extracted endpoint script'
    Assert-True ($payloadText -like '*exit /b %code%*') 'Action1 payload exits with endpoint exit code'
    Assert-True ($payloadResult.Output -like '*bytes*') 'Action1 payload builder reports payload size'

    $missingPayloadRoot = Join-Path $payloadTempRoot 'missing-webdeploy-root'
    $payloadExecutionResult = Invoke-Payload -PayloadPath $payloadOutput -Arguments @('-WebDeployRoot', $missingPayloadRoot, '-RunningProcessPolicy', 'Fail')
    Assert-True ($payloadExecutionResult.ExitCode -ne 0) 'Action1 generated payload smoke test returns endpoint failure code'
    Assert-True ($payloadExecutionResult.Output -like "*$missingPayloadRoot*") 'Action1 generated payload forwards WebDeployRoot argument during smoke test'
}
finally {
    if (Test-Path -LiteralPath $payloadTempRoot) {
        Remove-Item -LiteralPath $payloadTempRoot -Recurse -Force
    }
}

$tempRoot = Join-Path $env:TEMP ('fmu-test-' + [guid]::NewGuid().ToString('N'))
$streamerDir = Join-Path $tempRoot 'Autodesk\webdeploy\meta\streamer\20260227094542'
New-Item -ItemType Directory -Path $streamerDir -Force | Out-Null
New-Item -ItemType File -Path (Join-Path $streamerDir 'streamer.exe') -Force | Out-Null

$foundStreamer = Get-LatestFusionStreamer -WebDeployRoot (Join-Path $tempRoot 'Autodesk\webdeploy')
Assert-True ($foundStreamer -like '*streamer.exe') 'Latest streamer path is detected'

Remove-Item -LiteralPath $tempRoot -Recurse -Force

$tempRoot = Join-Path $env:TEMP ('fmu-test-' + [guid]::NewGuid().ToString('N'))
$streamerRoot = Join-Path $tempRoot 'Autodesk\webdeploy\meta\streamer'
$oldStreamerDir = Join-Path $streamerRoot '20250101000000'
$newStreamerDir = Join-Path $streamerRoot '20260227094542'
New-Item -ItemType Directory -Path $oldStreamerDir, $newStreamerDir -Force | Out-Null
New-Item -ItemType File -Path (Join-Path $oldStreamerDir 'streamer.exe') -Force | Out-Null
New-Item -ItemType File -Path (Join-Path $newStreamerDir 'streamer.exe') -Force | Out-Null

$latestStreamer = Get-LatestFusionStreamer -WebDeployRoot (Join-Path $tempRoot 'Autodesk\webdeploy')
Assert-Equal $latestStreamer (Join-Path $newStreamerDir 'streamer.exe') 'Latest streamer chooses highest named streamer directory'

Remove-Item -LiteralPath $tempRoot -Recurse -Force

$tempRoot = Join-Path $env:TEMP ('fmu-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $tempRoot 'Autodesk\webdeploy\meta\streamer\20260227094542') -Force | Out-Null

Assert-ThrowsLike { Get-LatestFusionStreamer -WebDeployRoot (Join-Path $tempRoot 'Autodesk\webdeploy') } '*No streamer.exe was found under:*' 'Latest streamer throws when no streamer executable exists'

Remove-Item -LiteralPath $tempRoot -Recurse -Force

$candidateProcesses = @(
    [pscustomobject]@{ ProcessName = 'Fusion360'; Id = 1 },
    [pscustomobject]@{ ProcessName = 'FusionLauncher'; Id = 2 },
    [pscustomobject]@{ ProcessName = 'FusionService'; Id = 3 },
    [pscustomobject]@{ ProcessName = 'Autodesk Fusion 360'; Id = 4 },
    [pscustomobject]@{ ProcessName = 'notepad'; Id = 5 }
)
$blockingProcesses = @(Get-FusionBlockingProcesses -Processes $candidateProcesses)
Assert-Equal $blockingProcesses.Count 2 'Fusion blocking process helper returns only user-facing Fusion process names'
Assert-True (($blockingProcesses.ProcessName -contains 'Fusion360') -and ($blockingProcesses.ProcessName -contains 'FusionLauncher')) 'Fusion blocking process helper includes expected process names'
Assert-True ($blockingProcesses.ProcessName -notcontains 'FusionService') 'Fusion blocking process helper excludes service-like background process names'
Assert-True ($blockingProcesses.ProcessName -notcontains 'Autodesk Fusion 360') 'Fusion blocking process helper excludes display names with spaces'

$missingRoot = Join-Path $env:TEMP ('fmu-missing-' + [guid]::NewGuid().ToString('N'))
$missingRootResult = Invoke-EndpointScript -Arguments @('-WebDeployRoot', $missingRoot)
Assert-True ($missingRootResult.ExitCode -ne 0) 'Endpoint updater fails when webdeploy root is missing'
Assert-True ($missingRootResult.Output -like '*All-users Fusion webdeploy root was not found*') 'Endpoint updater reports missing webdeploy root'

$tempRoot = Join-Path $env:TEMP ('fmu-test-' + [guid]::NewGuid().ToString('N'))
$webDeployRoot = Join-Path $tempRoot 'Autodesk\webdeploy'
$fakeStreamer = Join-Path $tempRoot 'fake-streamer.ps1'
$markerPath = Join-Path $tempRoot 'infofiles.txt'
New-Item -ItemType Directory -Path $webDeployRoot -Force | Out-Null
New-Item -ItemType File -Path $markerPath -Force | Out-Null
Set-Content -LiteralPath $fakeStreamer -Encoding ASCII -Value @(
    '$mode = $null',
    '$info = $null',
    'for ($i = 0; $i -lt $args.Count; $i++) {',
    '    if ($args[$i] -eq ''--process'' -and ($i + 1) -lt $args.Count) { $mode = $args[$i + 1] }',
    '    if ($args[$i] -eq ''--infofile'' -and ($i + 1) -lt $args.Count) { $info = $args[$i + 1] }',
    '}',
    'if ($mode -eq ''query'') {',
    '    Add-Content -LiteralPath $env:FMU_TEST_MARKER -Value $info',
    '    Set-Content -LiteralPath $info -Encoding ASCII -Value ''{"manifest":{"build-version":"","major-update-version":"","release-version":"test","streamer":{"feature-version":"test","release-id":"test"},"properties":{"display-name":"Autodesk Fusion"}},"install_path":"C:\\Fake","connection":"offline","stream":"test"}''',
    '    exit 0',
    '}',
    'if ($mode -eq ''update'') { exit 0 }',
    'exit 9'
)

$previousMarker = $env:FMU_TEST_MARKER
$env:FMU_TEST_MARKER = $markerPath
try {
    $emptyBuildResult = Invoke-EndpointScript -Arguments @('-WebDeployRoot', $webDeployRoot, '-StreamerPathOverride', $fakeStreamer)
    Assert-True ($emptyBuildResult.ExitCode -ne 0) 'Endpoint updater fails when post-update build version is empty'
    Assert-True ($emptyBuildResult.Output -like '*Post-update verification did not return a Fusion build version*') 'Endpoint updater reports empty post-update build version'

    $queryFiles = @(Get-Content -LiteralPath $markerPath | Where-Object { $_ })
    Assert-Equal $queryFiles.Count 2 'Fake streamer captured before and after query info files'
    foreach ($queryFile in $queryFiles) {
        Assert-True (-not (Test-Path -LiteralPath $queryFile)) "Endpoint updater removes temp query file $queryFile"
    }
}
finally {
    $env:FMU_TEST_MARKER = $previousMarker
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}

$tempRoot = Join-Path $env:TEMP ('fmu-test-' + [guid]::NewGuid().ToString('N'))
$webDeployRoot = Join-Path $tempRoot 'Autodesk\webdeploy'
$fakeStreamer = Join-Path $tempRoot 'fake-streamer-success.ps1'
$markerPath = Join-Path $tempRoot 'operations.txt'
New-Item -ItemType Directory -Path $webDeployRoot -Force | Out-Null
New-Item -ItemType File -Path $markerPath -Force | Out-Null
Set-Content -LiteralPath $fakeStreamer -Encoding ASCII -Value @(
    '$mode = $null',
    '$info = $null',
    'for ($i = 0; $i -lt $args.Count; $i++) {',
    '    if ($args[$i] -eq ''--process'' -and ($i + 1) -lt $args.Count) { $mode = $args[$i + 1] }',
    '    if ($args[$i] -eq ''--infofile'' -and ($i + 1) -lt $args.Count) { $info = $args[$i + 1] }',
    '}',
    'Add-Content -LiteralPath $env:FMU_TEST_MARKER -Value $mode',
    'if ($mode -eq ''query'') {',
    '    Add-Content -LiteralPath $env:FMU_TEST_MARKER -Value "info=$info"',
    '    Set-Content -LiteralPath $info -Encoding ASCII -Value ''{"manifest":{"build-version":"2702.1.58","major-update-version":"","release-version":"test","streamer":{"feature-version":"test","release-id":"test"},"properties":{"display-name":"Autodesk Fusion"}},"install_path":"C:\\Fake","connection":"offline","stream":"test"}''',
    '    exit 0',
    '}',
    'if ($mode -eq ''update'') { exit 0 }',
    'exit 9'
)

$previousMarker = $env:FMU_TEST_MARKER
$env:FMU_TEST_MARKER = $markerPath
try {
    $successResult = Invoke-EndpointScript -Arguments @('-WebDeployRoot', $webDeployRoot, '-StreamerPathOverride', $fakeStreamer)
    Assert-Equal $successResult.ExitCode 0 'Endpoint updater exits 0 when post-update build version exists'

    $operations = @(Get-Content -LiteralPath $markerPath | Where-Object { $_ -and ($_ -notlike 'info=*') })
    Assert-Equal ($operations -join ',') 'query,update,query' 'Endpoint updater runs query-update-query on success path'

    $queryFiles = @(Get-Content -LiteralPath $markerPath | Where-Object { $_ -like 'info=*' } | ForEach-Object { $_.Substring(5) })
    Assert-Equal $queryFiles.Count 2 'Success fake streamer captured before and after query info files'
    foreach ($queryFile in $queryFiles) {
        Assert-True (-not (Test-Path -LiteralPath $queryFile)) "Endpoint updater removes success temp query file $queryFile"
    }
}
finally {
    $env:FMU_TEST_MARKER = $previousMarker
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}
