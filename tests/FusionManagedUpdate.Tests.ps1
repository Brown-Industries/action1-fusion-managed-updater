$repoRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repoRoot 'src/FusionManagedUpdate.Common.psm1'
Import-Module $modulePath -Force

$fixtureRoot = Join-Path $PSScriptRoot 'fixtures'
$endpointScript = Join-Path $repoRoot 'src/Invoke-FusionManagedUpdate.ps1'
$payloadBuilder = Join-Path $repoRoot 'packaging/build-action1-payload.ps1'

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
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $endpointScript @Arguments 2>&1
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
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $payloadBuilder -OutputPath $OutputPath 2>&1
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

$versionDescription = New-HistoricalVersionWarning -BuildVersion '2702.1.58' -DetectedDate '2026-04-30'
$versionBody = New-Action1FusionVersionBody -BuildVersion '2702.1.58' -DetectedDate '2026-04-30' -PayloadFileName 'FusionManagedUpdater.cmd'
Assert-Equal $versionBody.version '2702.1.58' 'Action1 version body uses Fusion build version'
Assert-Equal $versionBody.app_name_match '^Autodesk Fusion(?: 360)?$' 'Action1 version body matches current and legacy Fusion names'
Assert-True ($versionBody.description -eq $versionDescription) 'Action1 version body includes historical warning'
Assert-Equal $versionBody.silent_install_switches '' 'Action1 payload launcher needs no switches'
Assert-Equal $versionBody.success_exit_codes '0' 'Action1 success exit code is zero'

$unchangedDryRun = New-FusionWatcherDryRunResult -State $autodeskHead -AutodeskHead $autodeskHead -BuildVersion '2702.1.58' -DetectedDate '2026-04-30' -PayloadFileName 'FusionManagedUpdater.cmd'
Assert-Equal $unchangedDryRun.Changed $false 'Fusion watcher dry-run result reports unchanged installer state'
Assert-Equal $unchangedDryRun.AutodeskHead.ETag $autodeskHead.ETag 'Fusion watcher dry-run result includes Autodesk HEAD when unchanged'
Assert-Equal $unchangedDryRun.Action1VersionBody.version '2702.1.58' 'Fusion watcher dry-run result includes Action1 version body when unchanged'

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
    Assert-True ($payloadText -like '*powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ps1%"*') 'Action1 payload runs extracted endpoint script'
    Assert-True ($payloadText -like '*exit /b %code%*') 'Action1 payload exits with endpoint exit code'
    Assert-True ($payloadResult.Output -like '*bytes*') 'Action1 payload builder reports payload size'
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
