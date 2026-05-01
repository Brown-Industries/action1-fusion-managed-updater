$repoRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repoRoot 'src/FusionManagedUpdate.Common.psm1'
Import-Module $modulePath -Force
$action1ModulePath = Join-Path $repoRoot 'src/Action1Repository.psm1'
if (Test-Path -LiteralPath $action1ModulePath) {
    Import-Module $action1ModulePath -Force -DisableNameChecking
}

$fixtureRoot = Join-Path $PSScriptRoot 'fixtures'
$endpointScript = Join-Path $repoRoot 'src/Invoke-FusionManagedUpdate.ps1'
$watcherScript = Join-Path $repoRoot 'src/Watch-FusionAction1Release.ps1'
$syncScript = Join-Path $repoRoot 'src/Invoke-FusionAction1RepositorySync.ps1'
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

function Assert-ThrowsLikeAndNotLike {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string[]]$ForbiddenPatterns,
        [Parameter(Mandatory = $true)][string]$Message
    )

    try {
        & $ScriptBlock
        Assert-True $false $Message
    }
    catch {
        $exceptionMessage = $_.Exception.Message
        Assert-True ($exceptionMessage -like $Pattern) $Message
        foreach ($forbiddenPattern in $ForbiddenPatterns) {
            Assert-True (-not ($exceptionMessage -like $forbiddenPattern)) "$Message does not leak $forbiddenPattern"
        }
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

function Invoke-SyncScript {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $testPowerShell -NoProfile -ExecutionPolicy Bypass -File $syncScript @Arguments 2>&1
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
        $output = & $testPowerShell -NoProfile -ExecutionPolicy Bypass -File $PayloadPath @Arguments 2>&1
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

$versionBody = New-Action1FusionVersionBody -BuildVersion '2702.1.58' -DetectedDate '2026-04-30' -PayloadFileName 'FusionManagedUpdater.ps1'
Assert-Equal $versionBody.version '2702.1.58' 'Action1 version body uses Fusion build version'
Assert-Equal $versionBody.app_name_match '^Autodesk Fusion(?: 360)?$' 'Action1 version body matches current and legacy Fusion names'
Assert-True (-not $versionBody.Contains('description')) 'Action1 version body omits non-settable description field'
Assert-True (-not $versionBody.Contains('internal_notes')) 'Action1 version body omits non-settable internal notes field'
Assert-Equal $versionBody.install_type 'exe' 'Action1 PowerShell payload uses non-MSI API installation type'
Assert-Equal $versionBody.silent_install_switches '' 'Action1 single-file payload does not pass itself as an install switch'
Assert-Equal $versionBody.success_exit_codes '0' 'Action1 success exit code is zero'
Assert-Equal $versionBody.reboot_exit_codes '1,1641,3010' 'Action1 version body uses deployable reboot exit codes'
Assert-Equal $versionBody.EULA_accepted 'no' 'Action1 version body initializes EULA metadata for custom package deployment'

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

$blankOptionalConfig = Get-FusionContainerRuntimeConfig -Environment @{
    ACTION1_CLIENT_ID = 'client-id'
    ACTION1_CLIENT_SECRET = 'client-secret'
    ACTION1_BASE_URL = ''
    ACTION1_ORG_ID = ' '
    PACKAGE_NAME = $null
    CHECK_FREQUENCY_MINUTES = ''
    ONE_SHOT = ' '
}
Assert-Equal $blankOptionalConfig.Action1BaseUrl 'https://app.action1.com/api/3.0' 'Container config defaults blank injected Action1 base URL'
Assert-Equal $blankOptionalConfig.Action1OrgId 'all' 'Container config defaults blank injected Action1 org id'
Assert-Equal $blankOptionalConfig.PackageName 'Autodesk Fusion Managed Updater' 'Container config defaults blank injected package name'
Assert-Equal $blankOptionalConfig.CheckFrequencyMinutes 1440 'Container config defaults blank injected interval schedule'
Assert-Equal $blankOptionalConfig.OneShot $true 'Container config defaults blank injected one-shot setting'

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

$intervalCommand = New-FusionContainerScheduleCommand -Config ([pscustomobject]@{
    CheckFrequencyCron = ''
    CheckFrequencyMinutes = 1440
}) -SyncScriptPath '/app/src/Invoke-FusionAction1RepositorySync.ps1'
Assert-Equal $intervalCommand.Kind 'Interval' 'Schedule command defaults to interval mode'
Assert-Equal $intervalCommand.Seconds 86400 'Schedule command converts minutes to seconds'

$cronCommand = New-FusionContainerScheduleCommand -Config ([pscustomobject]@{
    CheckFrequencyCron = '0 */6 * * *'
    CheckFrequencyMinutes = 1440
}) -SyncScriptPath '/app/src/Invoke-FusionAction1RepositorySync.ps1'
Assert-Equal $cronCommand.Kind 'Cron' 'Schedule command prefers cron mode'
Assert-Equal $cronCommand.Expression '0 */6 * * *' 'Schedule command preserves cron expression'
Assert-True ($cronCommand.Command -like '*Invoke-FusionAction1RepositorySync.ps1*') 'Schedule command includes sync script'

$unsafePathCommand = New-FusionContainerScheduleCommand -Config ([pscustomobject]@{
    CheckFrequencyCron = '0 */6 * * *'
    CheckFrequencyMinutes = 1440
}) -SyncScriptPath "/tmp/sync'; echo injected #.ps1"
Assert-Equal $unsafePathCommand.Command "pwsh -NoProfile -ExecutionPolicy Bypass -File '/tmp/sync'\''; echo injected #.ps1'" 'Schedule command shell-quotes sync script path'
Assert-True (-not ($unsafePathCommand.Command -like '*"/tmp/sync*')) 'Schedule command does not use unsafe double-quoted script path'

Assert-Equal (Assert-FusionContainerCronExpression -Expression '0 */6 * * *') '0 */6 * * *' 'Cron validation accepts five-field expression'

Assert-ThrowsLike {
    Assert-FusionContainerCronExpression -Expression "0 */6 * * *`n* * * * *"
} '*control characters*' 'Cron validation rejects embedded newlines'

Assert-ThrowsLike {
    Assert-FusionContainerCronExpression -Expression '0 */6 * *'
} '*five fields*' 'Cron validation rejects non-five-field expression'

Assert-ThrowsLike {
    New-FusionContainerScheduleCommand -Config ([pscustomobject]@{
        CheckFrequencyCron = '0 */6 * *'
        CheckFrequencyMinutes = 1440
    }) -SyncScriptPath '/app/src/Invoke-FusionAction1RepositorySync.ps1'
} '*five fields*' 'Schedule command validates cron expression before cron file generation'

$cronEnvSpec = New-FusionContainerCronEnvironmentSpec -Environment @{
    ACTION1_CLIENT_ID = 'client-id'
    ACTION1_CLIENT_SECRET = "secret'value"
    ACTION1_BASE_URL = 'https://app.action1.com/api/3.0'
    ACTION1_ORG_ID = 'all'
    PACKAGE_NAME = 'Autodesk Fusion Managed Updater'
    CHECK_FREQUENCY_CRON = '0 */6 * * *'
    CHECK_FREQUENCY_MINUTES = '1440'
    ONE_SHOT = 'false'
    PATH = '/usr/local/bin'
    UNRELATED_SECRET = 'do-not-write'
}
$cronEnvText = $cronEnvSpec.Lines -join "`n"
Assert-Equal $cronEnvSpec.Mode '0600' 'Cron environment spec locks down env file mode'
Assert-True ($cronEnvText -like "*ACTION1_CLIENT_ID='client-id'*") 'Cron environment includes Action1 client id'
Assert-True ($cronEnvText -like "*ACTION1_CLIENT_SECRET='secret'\''value'*") 'Cron environment escapes single quotes'
Assert-True ($cronEnvText -like "*CHECK_FREQUENCY_CRON='0 */6 * * *'*") 'Cron environment includes scheduling vars'
Assert-True (-not ($cronEnvText -like '*UNRELATED_SECRET*')) 'Cron environment excludes unrelated secrets'
Assert-True (-not ($cronEnvText -like '*PATH=*')) 'Cron environment excludes unrelated path var'

$oneShotStartupState = [pscustomobject]@{ Attempts = 0 }
Assert-ThrowsLike {
    Invoke-FusionContainerStartupSync -OneShot $true -SyncCommand {
        $oneShotStartupState.Attempts++
        throw 'startup failed'
    }
} '*startup failed*' 'One-shot startup sync failure fails fast'
Assert-Equal $oneShotStartupState.Attempts 1 'One-shot startup sync runs once'

$scheduledStartupState = [pscustomobject]@{ Attempts = 0; Logged = $null }
$scheduledStartupResult = Invoke-FusionContainerStartupSync -OneShot $false -SyncCommand {
    $scheduledStartupState.Attempts++
    throw 'transient startup failed'
} -LogCommand {
    param($ErrorRecord)
    $scheduledStartupState.Logged = [string]$ErrorRecord
}
Assert-Equal $scheduledStartupResult.Succeeded $false 'Scheduled startup sync failure is captured'
Assert-Equal $scheduledStartupResult.ContinueScheduling $true 'Scheduled startup sync failure continues scheduling'
Assert-Equal $scheduledStartupState.Attempts 1 'Scheduled startup sync runs once before continuing'
Assert-True ($scheduledStartupState.Logged -like '*transient startup failed*') 'Scheduled startup sync logs startup failure'

$failingSyncScript = Join-Path ([System.IO.Path]::GetTempPath()) "fusion-sync-fails-$([guid]::NewGuid().ToString('N')).ps1"
try {
    Set-Content -LiteralPath $failingSyncScript -Value 'exit 17' -Encoding ASCII
    Assert-ThrowsLike {
        Invoke-FusionContainerSyncOnce -ScriptPath $failingSyncScript -PowerShellCommand $testPowerShell
    } '*exited with code 17*' 'Container sync wrapper throws on child process nonzero exit'
}
finally {
    Remove-Item -LiteralPath $failingSyncScript -Force -ErrorAction SilentlyContinue
}

Assert-ThrowsLike {
    Get-FusionContainerRuntimeConfig -Environment @{ ACTION1_CLIENT_ID = 'client-id' }
} '*ACTION1_CLIENT_SECRET*' 'Container config requires Action1 client secret'

Assert-ThrowsLike {
    Get-FusionContainerRuntimeConfig -Environment @{ ACTION1_CLIENT_SECRET = 'client-secret' }
} '*ACTION1_CLIENT_ID*' 'Container config requires Action1 client id'

$tokenBody = New-Action1TokenRequestBody -ClientId 'client 1' -ClientSecret 'secret/2'
Assert-True ($tokenBody -like '*grant_type=client_credentials*') 'Token body uses client credentials grant'
Assert-True ($tokenBody -like '*client_id=client+1*') 'Token body form-encodes client id'
Assert-True ($tokenBody -like '*client_secret=secret%2F2*') 'Token body form-encodes client secret'

$matchingPackages = [pscustomobject]@{
    items = @(
        [pscustomobject]@{ id = 'pkg-1'; name = 'Autodesk Fusion Managed Updater'; builtin = 'no' },
        [pscustomobject]@{ id = 'pkg-2'; name = 'Autodesk Fusion Managed Updater Extra'; builtin = 'no' }
    )
}
$selectedPackage = Select-Action1PackageByExactName -Packages $matchingPackages -PackageName 'Autodesk Fusion Managed Updater'
Assert-Equal $selectedPackage.id 'pkg-1' 'Package selector returns exact package name'

$noPackage = Select-Action1PackageByExactName -Packages ([pscustomobject]@{ items = @() }) -PackageName 'Autodesk Fusion Managed Updater'
Assert-True ($null -eq $noPackage) 'Package selector returns null for no exact package'

$duplicatePackages = [pscustomobject]@{
    items = @(
        [pscustomobject]@{ id = 'pkg-1'; name = 'Autodesk Fusion Managed Updater'; builtin = 'no' },
        [pscustomobject]@{ id = 'pkg-2'; name = 'autodesk fusion managed updater'; builtin = 'no' }
    )
}
Assert-ThrowsLike {
    Select-Action1PackageByExactName -Packages $duplicatePackages -PackageName 'Autodesk Fusion Managed Updater'
} '*Multiple Action1 packages*' 'Package selector rejects duplicate exact names'

$existingPackageCalls = @()
$existingPackage = Ensure-Action1PackageByName -BaseUrl 'https://action1.invalid/api/3.0' -OrgId 'all' -AccessToken 'token' -PackageName 'Autodesk Fusion Managed Updater' -RequestCommand {
    param($Method, $Path, $Body)
    $script:existingPackageCalls += "$Method $Path"
    if ($Method -eq 'GET') {
        return [pscustomobject]@{ items = @([pscustomobject]@{ id = 'pkg-1'; name = 'Autodesk Fusion Managed Updater' }) }
    }
    throw 'POST should not be called for existing package'
}
Assert-Equal $existingPackage.id 'pkg-1' 'Ensure package returns existing exact-name package'
Assert-True (($existingPackageCalls -join ',') -like 'GET /software-repository/all*') 'Ensure package searches software repository'

$createdPackageCalls = @()
$createdPackageBody = $null
$createdPackage = Ensure-Action1PackageByName -BaseUrl 'https://action1.invalid/api/3.0' -OrgId 'all' -AccessToken 'token' -PackageName 'Autodesk Fusion Managed Updater' -RequestCommand {
    param($Method, $Path, $Body)
    $script:createdPackageCalls += "$Method $Path"
    if ($Method -eq 'GET') { return [pscustomobject]@{ items = @() } }
    if ($Method -eq 'POST') {
        $script:createdPackageBody = $Body
        return [pscustomobject]@{ id = 'pkg-new'; name = $Body.name }
    }
}
Assert-Equal $createdPackage.id 'pkg-new' 'Ensure package creates missing package'
Assert-True (($createdPackageCalls -join ',') -like '*POST /software-repository/all*') 'Ensure package posts missing package'
Assert-Equal $createdPackageBody.name 'Autodesk Fusion Managed Updater' 'Ensure package create body uses requested package name'
Assert-Equal $createdPackageBody.vendor 'Autodesk' 'Ensure package create body uses Autodesk vendor'
Assert-Equal $createdPackageBody.platform 'Windows' 'Ensure package create body targets Windows'
Assert-True ($createdPackageBody.description -like '*Historical versions are release records only*') 'Ensure package create body warns about historical records'
Assert-True ($createdPackageBody.internal_notes -like '*Do not use this package for rollback*') 'Ensure package create body warns against rollback'

$packageBody = New-Action1FusionPackageBody -PackageName 'Autodesk Fusion Managed Updater'
Assert-Equal $packageBody.name 'Autodesk Fusion Managed Updater' 'Package body uses requested package name'
Assert-Equal $packageBody.vendor 'Autodesk' 'Package body uses Autodesk vendor'
Assert-Equal $packageBody.platform 'Windows' 'Package body targets Windows'
Assert-True ($packageBody.description -like '*Historical versions are release records only*') 'Package body warns about historical records'
Assert-True ($packageBody.internal_notes -like '*Do not use this package for rollback*') 'Package body warns against rollback'

$uploadHeaders = New-Action1UploadInitHeaders -AccessToken 'token' -PayloadLength 123
Assert-Equal $uploadHeaders.Authorization 'Bearer token' 'Upload init includes bearer token'
Assert-Equal $uploadHeaders.'X-Upload-Content-Type' 'application/octet-stream' 'Upload init sets content type header'
Assert-Equal $uploadHeaders.'X-Upload-Content-Length' '123' 'Upload init sets content length header'

$putHeaders = New-Action1UploadPutHeaders -AccessToken 'token' -PayloadLength 123
Assert-Equal $putHeaders.Authorization 'Bearer token' 'Upload PUT includes bearer token'
Assert-Equal $putHeaders.'Content-Range' 'bytes 0-122/123' 'Upload PUT sets content range'

Assert-ThrowsLike { New-Action1UploadInitHeaders -AccessToken 'token' -PayloadLength 0 } '*PayloadLength must be at least 1*' 'Upload init rejects zero payload length'
Assert-ThrowsLike { New-Action1UploadInitHeaders -AccessToken 'token' -PayloadLength -1 } '*PayloadLength must be at least 1*' 'Upload init rejects negative payload length'
Assert-ThrowsLike { New-Action1UploadPutHeaders -AccessToken 'token' -PayloadLength 0 } '*PayloadLength must be at least 1*' 'Upload PUT rejects zero payload length'
Assert-ThrowsLike { New-Action1UploadPutHeaders -AccessToken 'token' -PayloadLength -1 } '*PayloadLength must be at least 1*' 'Upload PUT rejects negative payload length'

$uploadTempRoot = Join-Path $env:TEMP ('fmu-upload-test-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $uploadTempRoot -Force | Out-Null
    $emptyPayloadPath = Join-Path $uploadTempRoot 'empty.cmd'
    Set-Content -LiteralPath $emptyPayloadPath -Encoding ASCII -NoNewline -Value ''
    $uploadCalls = @()
    Assert-ThrowsLike {
        Send-Action1VersionPayload -BaseUrl 'https://action1.invalid/api/3.0' -OrgId 'all' -PackageId 'pkg-1' -VersionId 'ver-1' -AccessToken 'secret-token' -PayloadPath $emptyPayloadPath -RequestCommand {
            param($Method, $Uri, $Headers, $ContentType, $Body)
            $script:uploadCalls += $Method
        }
    } '*Payload file must not be empty*' 'Version payload upload rejects empty payload before init'
    Assert-Equal $uploadCalls.Count 0 'Version payload upload does not initialize empty payload'

    $payloadPath = Join-Path $uploadTempRoot 'payload.cmd'
    [IO.File]::WriteAllBytes($payloadPath, [byte[]](65, 66, 67))

    Assert-ThrowsLikeAndNotLike {
        Send-Action1VersionPayload -BaseUrl 'https://action1.invalid/api/3.0' -OrgId 'all' -PackageId 'pkg-1' -VersionId 'ver-1' -AccessToken 'secret-token' -PayloadPath $payloadPath -RequestCommand {
            param($Method, $Uri, $Headers, $ContentType, $Body)
            return [pscustomobject]@{ StatusCode = 401; Headers = @{ 'X-Upload-Location' = 'https://action1.invalid/api/3.0/upload/session-1' } }
        }
    } '*pkg-1*ver-1*401*' @('*secret-token*', '*https://action1.invalid/api/3.0*') 'Version payload upload reports init non-2xx status with sanitized context'

    Assert-ThrowsLikeAndNotLike {
        Send-Action1VersionPayload -BaseUrl 'https://action1.invalid/api/3.0' -OrgId 'all' -PackageId 'pkg-1' -VersionId 'ver-1' -AccessToken 'secret-token' -PayloadPath $payloadPath -RequestCommand {
            param($Method, $Uri, $Headers, $ContentType, $Body)
            throw 'simulated init transport failure https://action1.invalid/api/3.0/software-repository/all/pkg-1/versions/ver-1/upload?platform=Windows_64 Bearer secret-token'
        }
    } '*init*pkg-1*ver-1*' @('*Bearer*', '*secret-token*', '*https://action1.invalid/api/3.0*') 'Version payload upload sanitizes init transport failures'

    Assert-ThrowsLikeAndNotLike {
        Send-Action1VersionPayload -BaseUrl 'https://action1.invalid/api/3.0' -OrgId 'all' -PackageId 'pkg-1' -VersionId 'ver-1' -AccessToken 'secret-token' -PayloadPath $payloadPath -RequestCommand {
            param($Method, $Uri, $Headers, $ContentType, $Body)
            return [pscustomobject]@{ StatusCode = 200; Headers = @{} }
        }
    } '*X-Upload-Location*pkg-1*ver-1*' @('*secret-token*', '*https://action1.invalid/api/3.0*') 'Version payload upload reports missing upload location with sanitized context'

    $mismatchCalls = @()
    Assert-ThrowsLikeAndNotLike {
        Send-Action1VersionPayload -BaseUrl 'https://action1.invalid/api/3.0' -OrgId 'all' -PackageId 'pkg-1' -VersionId 'ver-1' -AccessToken 'secret-token' -PayloadPath $payloadPath -RequestCommand {
            param($Method, $Uri, $Headers, $ContentType, $Body)
            $script:mismatchCalls += $Method
            if ($Method -eq 'POST') {
                return [pscustomobject]@{ StatusCode = 200; Headers = @{ 'X-Upload-Location' = 'https://evil.invalid/upload/session-1' } }
            }
            throw 'PUT should not be called for mismatched upload host'
        }
    } '*unexpected host*pkg-1*ver-1*' @('*secret-token*', '*evil.invalid/upload/session-1*') 'Version payload upload rejects mismatched upload host with sanitized context'
    Assert-Equal ($mismatchCalls -join ',') 'POST' 'Version payload upload does not PUT to mismatched upload host'

    $portMismatchCalls = @()
    Assert-ThrowsLikeAndNotLike {
        Send-Action1VersionPayload -BaseUrl 'https://action1.invalid:443/api/3.0' -OrgId 'all' -PackageId 'pkg-1' -VersionId 'ver-1' -AccessToken 'secret-token' -PayloadPath $payloadPath -RequestCommand {
            param($Method, $Uri, $Headers, $ContentType, $Body)
            $script:portMismatchCalls += $Method
            if ($Method -eq 'POST') {
                return [pscustomobject]@{ StatusCode = 200; Headers = @{ 'X-Upload-Location' = 'https://action1.invalid:444/api/3.0/upload/session-1' } }
            }
            throw 'PUT should not be called for mismatched upload port'
        }
    } '*unexpected host*pkg-1*ver-1*' @('*secret-token*', '*:444/api/3.0/upload/session-1*') 'Version payload upload rejects mismatched upload port with sanitized context'
    Assert-Equal ($portMismatchCalls -join ',') 'POST' 'Version payload upload does not PUT to mismatched upload port'

    Assert-ThrowsLikeAndNotLike {
        Send-Action1VersionPayload -BaseUrl 'https://action1.invalid/api/3.0' -OrgId 'all' -PackageId 'pkg-1' -VersionId 'ver-1' -AccessToken 'secret-token' -PayloadPath $payloadPath -RequestCommand {
            param($Method, $Uri, $Headers, $ContentType, $Body)
            if ($Method -eq 'POST') {
                return [pscustomobject]@{ StatusCode = 200; Headers = @{ 'X-Upload-Location' = 'https://action1.invalid/api/3.0/upload/session-1' } }
            }
            throw 'simulated transport failure https://action1.invalid/api/3.0/upload/session-1 secret-token'
        }
    } '*PUT*pkg-1*ver-1*' @('*secret-token*', '*upload/session-1*') 'Version payload upload sanitizes PUT failures'

    $successfulUploadCalls = @()
    Send-Action1VersionPayload -BaseUrl 'https://action1.invalid/api/3.0' -OrgId 'all' -PackageId 'pkg-1' -VersionId 'ver-1' -AccessToken 'secret-token' -PayloadPath $payloadPath -RequestCommand {
        param($Method, $Uri, $Headers, $ContentType, $Body)
        $script:successfulUploadCalls += [pscustomobject]@{
            Method      = $Method
            UriHost     = ([uri]$Uri).Host
            UriPath     = ([uri]$Uri).AbsolutePath
            UriQuery    = ([uri]$Uri).Query
            Headers     = $Headers
            ContentType = $ContentType
            Body        = $Body
        }
        if ($Method -eq 'POST') {
            return [pscustomobject]@{ StatusCode = 308; Headers = @{ 'X-Upload-Location' = 'https://action1.invalid/api/3.0/upload/session-1?upload_id=upload-1&platform=Windows_64' } }
        }
        return [pscustomobject]@{ StatusCode = 200; Headers = @{} }
    }
    Assert-Equal $successfulUploadCalls.Count 2 'Version payload upload sends init and PUT requests'
    Assert-Equal $successfulUploadCalls[0].Method 'POST' 'Version payload upload initializes with POST'
    Assert-Equal $successfulUploadCalls[0].UriHost 'action1.invalid' 'Version payload upload init uses base host'
    Assert-Equal $successfulUploadCalls[0].Headers.Authorization 'Bearer secret-token' 'Version payload upload init sends bearer token'
    Assert-Equal $successfulUploadCalls[0].Headers.'X-Upload-Content-Length' '3' 'Version payload upload init sends payload length'
    Assert-Equal $successfulUploadCalls[1].Method 'PUT' 'Version payload upload sends payload with PUT'
    Assert-Equal $successfulUploadCalls[1].UriHost 'action1.invalid' 'Version payload upload PUT uses allowed host'
    Assert-Equal $successfulUploadCalls[1].UriQuery '?upload_id=upload-1&platform=Windows_64' 'Version payload upload PUT uses Action1 upload session query'
    Assert-Equal $successfulUploadCalls[1].Headers.Authorization 'Bearer secret-token' 'Version payload upload PUT sends bearer token'
    Assert-Equal $successfulUploadCalls[1].Headers.'Content-Range' 'bytes 0-2/3' 'Version payload upload PUT sends content range'
    Assert-Equal ([string]::Join(',', $successfulUploadCalls[1].Body)) '65,66,67' 'Version payload upload sends payload bytes'
}
finally {
    if (Test-Path -LiteralPath $uploadTempRoot) {
        Remove-Item -LiteralPath $uploadTempRoot -Recurse -Force
    }
}

$unchangedDryRun = New-FusionWatcherDryRunResult -State $autodeskHead -AutodeskHead $autodeskHead -BuildVersion '2702.1.58' -DetectedDate '2026-04-30' -PayloadFileName 'FusionManagedUpdater.ps1'
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
$packageWithBinary = [pscustomobject]@{
    versions = @(
        [pscustomobject]@{
            id = 'version-1'
            version = '2702.1.58'
            binary_id = [pscustomobject]@{ Windows_64 = 'binary-1' }
        }
    )
}
$versionRecord = Get-Action1PackageVersionRecord -Package $packageWithBinary -BuildVersion '2702.1.58'
Assert-Equal $versionRecord.id 'version-1' 'Version record helper returns matching version record'
Assert-True (Test-Action1PackageVersionHasWindowsBinary -VersionRecord $versionRecord) 'Version binary helper detects Windows binary'

$packageWithFieldVersion = [pscustomobject]@{
    versions = [pscustomobject]@{
        items = @(
            [pscustomobject]@{ id = 'field-version-1'; fields = [pscustomobject]@{ Version = '2702.1.58' } }
        )
    }
}
$fieldVersionRecord = Get-Action1PackageVersionRecord -Package $packageWithFieldVersion -BuildVersion '2702.1.58'
Assert-Equal $fieldVersionRecord.id 'field-version-1' 'Version record helper reads fields Version fallback'

$packageWithoutBinary = [pscustomobject]@{
    versions = @(
        [pscustomobject]@{ id = 'version-1'; version = '2702.1.58' }
    )
}
$missingBinaryRecord = Get-Action1PackageVersionRecord -Package $packageWithoutBinary -BuildVersion '2702.1.58'
Assert-True (-not (Test-Action1PackageVersionHasWindowsBinary -VersionRecord $missingBinaryRecord)) 'Version binary helper reports missing Windows binary'

$packageWithConfiguredFileButNoBinary = [pscustomobject]@{
    versions = @(
        [pscustomobject]@{
            id = 'version-1'
            version = '2702.1.58'
            file_name = [pscustomobject]@{ Windows_64 = [pscustomobject]@{ name = 'FusionManagedUpdater.ps1'; type = 'cloud' } }
        }
    )
}
$configuredFileRecord = Get-Action1PackageVersionRecord -Package $packageWithConfiguredFileButNoBinary -BuildVersion '2702.1.58'
Assert-True (-not (Test-Action1PackageVersionHasWindowsBinary -VersionRecord $configuredFileRecord)) 'Version binary helper does not treat configured file name as uploaded binary'
Assert-Equal (Resolve-Action1VersionSyncAction -Package $packageWithConfiguredFileButNoBinary -BuildVersion '2702.1.58') 'UploadMissingBinary' 'Version sync repairs configured file without binary id'

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Stop'
try {
    $nullBinaryRecord = [pscustomobject]@{ version = '2702.1.58'; binary_id = $null }
    Assert-True (-not (Test-Action1PackageVersionHasWindowsBinary -VersionRecord $nullBinaryRecord)) 'Version binary helper handles null binary id without error'
}
finally {
    $ErrorActionPreference = $previousErrorActionPreference
}

$recordedWithBinary = [pscustomobject]@{
    versions = @([pscustomobject]@{ id = 'version-1'; version = '2702.1.58'; binary_id = [pscustomobject]@{ Windows_64 = 'binary-1' } })
}
Assert-Equal (Resolve-Action1VersionSyncAction -Package $recordedWithBinary -BuildVersion '2702.1.58') 'NoOp' 'Version sync no-ops when binary exists'

$recordedWithoutBinary = [pscustomobject]@{
    versions = @([pscustomobject]@{ id = 'version-1'; version = '2702.1.58' })
}
Assert-Equal (Resolve-Action1VersionSyncAction -Package $recordedWithoutBinary -BuildVersion '2702.1.58') 'UploadMissingBinary' 'Version sync repairs missing binary'

$missingVersionPackage = [pscustomobject]@{ versions = @() }
Assert-Equal (Resolve-Action1VersionSyncAction -Package $missingVersionPackage -BuildVersion '2702.1.58') 'CreateAndUpload' 'Version sync creates missing version'

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

$syncTempRoot = Join-Path $env:TEMP ('fmu-sync-test-' + [guid]::NewGuid().ToString('N'))
$previousAction1ClientId = $env:ACTION1_CLIENT_ID
$previousAction1ClientSecret = $env:ACTION1_CLIENT_SECRET
$previousPackageName = $env:PACKAGE_NAME
try {
    New-Item -ItemType Directory -Path $syncTempRoot -Force | Out-Null
    $syncDefaultPayload = Join-Path $repoRoot 'dist/FusionManagedUpdater.ps1'
    $syncPayloadBuild = Invoke-PayloadBuilder -OutputPath $syncDefaultPayload
    Assert-Equal $syncPayloadBuild.ExitCode 0 'Stateless sync default payload is generated for tests'

    Set-Content -LiteralPath (Join-Path $syncTempRoot 'token.json') -Encoding ASCII -Value '{"access_token":"offline-token"}'
    Set-Content -LiteralPath (Join-Path $syncTempRoot 'packages.json') -Encoding ASCII -Value '{"items":[{"id":"pkg-1","name":"Autodesk Fusion Managed Updater"}]}'
    Set-Content -LiteralPath (Join-Path $syncTempRoot 'installed-software.json') -Encoding ASCII -Value ($inventory | ConvertTo-Json -Depth 20 -Compress)
    Set-Content -LiteralPath (Join-Path $syncTempRoot 'package.json') -Encoding ASCII -Value '{"id":"pkg-1","versions":[{"id":"version-1","version":"2702.1.58","binary_id":{"Windows_64":"binary-1"}}]}'

    $env:ACTION1_CLIENT_ID = 'client-id'
    $env:ACTION1_CLIENT_SECRET = 'client-secret'
    $env:PACKAGE_NAME = 'Autodesk Fusion Managed Updater'

    $syncScriptText = Get-Content -LiteralPath $syncScript -Raw
    Assert-True (-not $syncScriptText.Contains("'..\dist\FusionManagedUpdater.ps1'")) 'Stateless sync default payload path is built from portable path components'

    $noOpResult = Invoke-SyncScript -Arguments @('-OfflineFixtureRoot', $syncTempRoot)
    Assert-Equal $noOpResult.ExitCode 0 'Stateless sync exits 0 when version is already recorded'
    Assert-True ($noOpResult.Output -like '*already recorded*') 'Stateless sync reports already-recorded version'

    Set-Content -LiteralPath (Join-Path $syncTempRoot 'package.json') -Encoding ASCII -Value '{"id":"pkg-1","versions":[]}'
    Remove-Item -LiteralPath (Join-Path $syncTempRoot 'api-requests.log') -ErrorAction SilentlyContinue
    $createResult = Invoke-SyncScript -Arguments @('-OfflineFixtureRoot', $syncTempRoot, '-PayloadPath', (Join-Path $repoRoot 'dist/FusionManagedUpdater.ps1'))
    Assert-Equal $createResult.ExitCode 0 'Stateless sync exits 0 after creating and uploading missing version'
    Assert-True ($createResult.Output -like '*Created Action1 Fusion history version for 2702.1.58*') 'Stateless sync reports created version'
    $createRequests = @(Get-Content -LiteralPath (Join-Path $syncTempRoot 'api-requests.log'))
    Assert-True ($createRequests -contains 'GET /software-repository/all?custom=yes&filter=Autodesk%20Fusion%20Managed%20Updater&fields=*&limit=100') 'Stateless sync create flow queries packages'
    Assert-True ($createRequests -contains 'POST /software-repository/all/pkg-1/versions') 'Stateless sync create flow posts package version'
    Assert-True ($createRequests -contains 'UPLOAD /software-repository/all/pkg-1/versions/2702.1.58_offline/upload') 'Stateless sync create flow uploads created version payload'

    Set-Content -LiteralPath (Join-Path $syncTempRoot 'package.json') -Encoding ASCII -Value '{"id":"pkg-1","versions":[{"id":"version-1","version":"2702.1.58"}]}'
    Set-Content -LiteralPath (Join-Path $syncTempRoot 'version-detail.json') -Encoding ASCII -Value '{"id":"version-1","version":"2702.1.58","binary_id":{"Windows_64":"binary-1"}}'
    Remove-Item -LiteralPath (Join-Path $syncTempRoot 'api-requests.log') -ErrorAction SilentlyContinue
    $detailNoOpResult = Invoke-SyncScript -Arguments @('-OfflineFixtureRoot', $syncTempRoot)
    Assert-Equal $detailNoOpResult.ExitCode 0 'Stateless sync exits 0 when version detail confirms uploaded payload'
    Assert-True ($detailNoOpResult.Output -like '*already recorded*') 'Stateless sync reports already-recorded version from version detail'
    $detailNoOpRequests = @(Get-Content -LiteralPath (Join-Path $syncTempRoot 'api-requests.log'))
    Assert-True (-not ($detailNoOpRequests -contains 'UPLOAD /software-repository/all/pkg-1/versions/version-1/upload')) 'Stateless sync does not upload when version detail has binary'
    Remove-Item -LiteralPath (Join-Path $syncTempRoot 'version-detail.json') -ErrorAction SilentlyContinue

    Set-Content -LiteralPath (Join-Path $syncTempRoot 'package.json') -Encoding ASCII -Value '{"id":"pkg-1","versions":[{"id":"version-1","version":"2702.1.58"}]}'
    Remove-Item -LiteralPath (Join-Path $syncTempRoot 'api-requests.log') -ErrorAction SilentlyContinue
    $repairResult = Invoke-SyncScript -Arguments @('-OfflineFixtureRoot', $syncTempRoot)
    Assert-Equal $repairResult.ExitCode 0 'Stateless sync exits 0 after uploading missing binary'
    Assert-True ($repairResult.Output -like '*Uploaded missing Action1 payload for Fusion history version 2702.1.58*') 'Stateless sync reports missing binary upload'
    $repairRequests = @(Get-Content -LiteralPath (Join-Path $syncTempRoot 'api-requests.log'))
    Assert-True ($repairRequests -contains 'UPLOAD /software-repository/all/pkg-1/versions/version-1/upload') 'Stateless sync missing binary flow uploads existing version payload'
    Assert-True (-not ($repairRequests -contains 'POST /software-repository/all/pkg-1/versions')) 'Stateless sync missing binary flow does not create a version'

    Set-Content -LiteralPath (Join-Path $syncTempRoot 'packages.json') -Encoding ASCII -Value '{"items":[]}'
    Set-Content -LiteralPath (Join-Path $syncTempRoot 'package.json') -Encoding ASCII -Value '{"id":"pkg-created","versions":[]}'
    Remove-Item -LiteralPath (Join-Path $syncTempRoot 'api-requests.log') -ErrorAction SilentlyContinue
    $packageCreateResult = Invoke-SyncScript -Arguments @('-OfflineFixtureRoot', $syncTempRoot)
    Assert-Equal $packageCreateResult.ExitCode 0 'Stateless sync exits 0 after creating missing package'
    $packageCreateRequests = @(Get-Content -LiteralPath (Join-Path $syncTempRoot 'api-requests.log'))
    Assert-True ($packageCreateRequests -contains 'POST /software-repository/all') 'Stateless sync package create flow posts missing package'
    Assert-True ($packageCreateRequests -contains 'POST /software-repository/all/pkg-created/versions') 'Stateless sync package create flow creates version under created package'
    Assert-True ($packageCreateRequests -contains 'UPLOAD /software-repository/all/pkg-created/versions/2702.1.58_offline/upload') 'Stateless sync package create flow uploads under created package'

    Set-Content -LiteralPath (Join-Path $syncTempRoot 'packages.json') -Encoding ASCII -Value '{"items":[{"id":"pkg-1","name":"Autodesk Fusion Managed Updater"}]}'
    Set-Content -LiteralPath (Join-Path $syncTempRoot 'installed-software.json') -Encoding ASCII -Value '{"items":[]}'
    $missingInventoryResult = Invoke-SyncScript -Arguments @('-OfflineFixtureRoot', $syncTempRoot)
    Assert-True ($missingInventoryResult.ExitCode -ne 0) 'Stateless sync fails when inventory has no Fusion build'
    Assert-True ($missingInventoryResult.Output -like '*Action1 installed software inventory did not report an Autodesk Fusion build version for stateless repository sync*') 'Stateless sync reports actionable missing inventory error'
    Assert-True (-not ($missingInventoryResult.Output -like '*AllowManualObservedBuild*')) 'Stateless sync missing inventory error omits unsupported manual override advice'

    Set-Content -LiteralPath (Join-Path $syncTempRoot 'installed-software.json') -Encoding ASCII -Value ($inventory | ConvertTo-Json -Depth 20 -Compress)
    Set-Content -LiteralPath (Join-Path $syncTempRoot 'package.json') -Encoding ASCII -Value '{"id":"pkg-1","versions":[{"version":"2702.1.58"}]}'
    $missingExistingIdResult = Invoke-SyncScript -Arguments @('-OfflineFixtureRoot', $syncTempRoot)
    Assert-True ($missingExistingIdResult.ExitCode -ne 0) 'Stateless sync fails when existing version response has no id'
    Assert-True ($missingExistingIdResult.Output -like '*Action1 package version record for Fusion build 2702.1.58 did not include an id*') 'Stateless sync reports missing existing version id'

    Set-Content -LiteralPath (Join-Path $syncTempRoot 'package.json') -Encoding ASCII -Value '{"id":"pkg-1","versions":[]}'
    Set-Content -LiteralPath (Join-Path $syncTempRoot 'created-version-response.json') -Encoding ASCII -Value '{"version":"2702.1.58"}'
    $missingCreatedIdResult = Invoke-SyncScript -Arguments @('-OfflineFixtureRoot', $syncTempRoot)
    Assert-True ($missingCreatedIdResult.ExitCode -ne 0) 'Stateless sync fails when created version response has no id'
    Assert-True ($missingCreatedIdResult.Output -like '*Action1 create version response for Fusion build 2702.1.58 did not include an id*') 'Stateless sync reports missing created version id'
    Remove-Item -LiteralPath (Join-Path $syncTempRoot 'created-version-response.json') -ErrorAction SilentlyContinue
}
finally {
    if ($null -eq $previousAction1ClientId) { Remove-Item Env:\ACTION1_CLIENT_ID -ErrorAction SilentlyContinue } else { $env:ACTION1_CLIENT_ID = $previousAction1ClientId }
    if ($null -eq $previousAction1ClientSecret) { Remove-Item Env:\ACTION1_CLIENT_SECRET -ErrorAction SilentlyContinue } else { $env:ACTION1_CLIENT_SECRET = $previousAction1ClientSecret }
    if ($null -eq $previousPackageName) { Remove-Item Env:\PACKAGE_NAME -ErrorAction SilentlyContinue } else { $env:PACKAGE_NAME = $previousPackageName }
    if (Test-Path -LiteralPath $syncTempRoot) { Remove-Item -LiteralPath $syncTempRoot -Recurse -Force }
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
$payloadOutput = Join-Path $payloadTempRoot 'FusionManagedUpdater.ps1'
try {
    $payloadResult = Invoke-PayloadBuilder -OutputPath $payloadOutput
    Assert-Equal $payloadResult.ExitCode 0 'Action1 payload builder exits 0'
    Assert-True (Test-Path -LiteralPath $payloadOutput) 'Action1 payload builder writes requested output path'

    $payloadBytes = [IO.File]::ReadAllBytes($payloadOutput)
    $nonAsciiByte = $payloadBytes | Where-Object { $_ -gt 127 } | Select-Object -First 1
    Assert-True ($null -eq $nonAsciiByte) 'Action1 payload is ASCII-only'
    Assert-True ($payloadBytes.Length -lt 1MB) 'Action1 payload is under 1 MB'

    $payloadText = Get-Content -LiteralPath $payloadOutput -Raw
    Assert-True ($payloadText -like '*$moduleb64 = @(*') 'Action1 payload defines module base64 chunks'
    Assert-True ($payloadText -like '*$scriptb64 = @(*') 'Action1 payload defines script base64 chunks'
    Assert-True ($payloadText.Contains('[Convert]::FromBase64String')) 'Action1 payload decodes embedded files'
    Assert-True (-not ($payloadText -like '*>> "%*b64%" echo *')) 'Action1 payload does not rely on CMD echo for Base64 extraction'
    Assert-True ($payloadText -like '*powershell.exe'' -NoProfile -ExecutionPolicy Bypass -File $ps1 @args*') 'Action1 payload forwards launcher arguments to extracted endpoint script'
    Assert-True ($payloadText -like '*exit $exitCode*') 'Action1 payload exits with endpoint exit code'
    Assert-True ($payloadResult.Output -like '*bytes*') 'Action1 payload builder reports payload size'

    $missingPayloadRoot = Join-Path $payloadTempRoot 'missing-webdeploy-root'
    $payloadFakeInstaller = Join-Path $payloadTempRoot 'fake-admin-install-failure.ps1'
    Set-Content -LiteralPath $payloadFakeInstaller -Encoding ASCII -Value 'exit 22'
    $payloadExecutionResult = Invoke-Payload -PayloadPath $payloadOutput -Arguments @('-WebDeployRoot', $missingPayloadRoot, '-RunningProcessPolicy', 'Fail', '-AdminInstallerUrl', $payloadFakeInstaller, '-InstallerWorkRoot', $payloadTempRoot, '-LogPath', (Join-Path $payloadTempRoot 'payload-smoke.log'))
    Assert-True ($payloadExecutionResult.ExitCode -ne 0) 'Action1 generated payload smoke test returns endpoint failure code'
    Assert-True ($payloadExecutionResult.Output -like "*$missingPayloadRoot*") 'Action1 generated payload forwards WebDeployRoot argument during smoke test'
    $remainingPayloadInstallers = @(Get-ChildItem -LiteralPath $payloadTempRoot -Filter 'FusionAdminInstall-*' -File)
    Assert-Equal $remainingPayloadInstallers.Count 0 'Action1 generated payload deletes bootstrap installer after smoke-test failure'
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

$tempRoot = Join-Path $env:TEMP ('fmu-bootstrap-test-' + [guid]::NewGuid().ToString('N'))
$webDeployRoot = Join-Path $tempRoot 'Autodesk\webdeploy'
$fakeInstaller = Join-Path $tempRoot 'fake-admin-install.ps1'
$fakeStreamer = Join-Path $tempRoot 'fake-streamer-bootstrap.ps1'
$markerPath = Join-Path $tempRoot 'bootstrap-operations.txt'
$logPath = Join-Path $tempRoot 'FusionManagedUpdater.log'
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
New-Item -ItemType File -Path $markerPath -Force | Out-Null
Set-Content -LiteralPath $fakeInstaller -Encoding ASCII -Value @(
    'Add-Content -LiteralPath $env:FMU_TEST_MARKER -Value ("installer_args=" + ($args -join ","))',
    '$streamerDir = Join-Path $env:FMU_TEST_WEBDEPLOY_ROOT ''meta\streamer\20260501000000''',
    'New-Item -ItemType Directory -Path $streamerDir -Force | Out-Null',
    'exit 0'
)
Set-Content -LiteralPath $fakeStreamer -Encoding ASCII -Value @(
    '$mode = $null',
    '$info = $null',
    'for ($i = 0; $i -lt $args.Count; $i++) {',
    '    if ($args[$i] -eq ''--process'' -and ($i + 1) -lt $args.Count) { $mode = $args[$i + 1] }',
    '    if ($args[$i] -eq ''--infofile'' -and ($i + 1) -lt $args.Count) { $info = $args[$i + 1] }',
    '}',
    'Add-Content -LiteralPath $env:FMU_TEST_MARKER -Value $mode',
    'if ($mode -eq ''query'') {',
    '    Set-Content -LiteralPath $info -Encoding ASCII -Value ''{"manifest":{"build-version":"2702.1.58","major-update-version":"","release-version":"test","streamer":{"feature-version":"test","release-id":"test"},"properties":{"display-name":"Autodesk Fusion"}},"install_path":"C:\\Fake","connection":"offline","stream":"test"}''',
    '    exit 0',
    '}',
    'exit 9'
)

$previousMarker = $env:FMU_TEST_MARKER
$previousWebDeployRoot = $env:FMU_TEST_WEBDEPLOY_ROOT
$env:FMU_TEST_MARKER = $markerPath
$env:FMU_TEST_WEBDEPLOY_ROOT = $webDeployRoot
try {
    $bootstrapResult = Invoke-EndpointScript -Arguments @('-WebDeployRoot', $webDeployRoot, '-AdminInstallerUrl', $fakeInstaller, '-InstallerWorkRoot', $tempRoot, '-StreamerPathOverride', $fakeStreamer, '-LogPath', $logPath)
    Assert-Equal $bootstrapResult.ExitCode 0 'Endpoint updater exits 0 after bootstrapping missing all-users Fusion'
    Assert-True ($bootstrapResult.Output -like '*FMU_STEP bootstrap_download_start*') 'Endpoint updater reports bootstrap download start to Action1 output'
    Assert-True ($bootstrapResult.Output -like '*FMU_STEP bootstrap_install_start*') 'Endpoint updater reports bootstrap install start to Action1 output'
    Assert-True ($bootstrapResult.Output -like '*FMU_STEP verification_success*') 'Endpoint updater reports verification success to Action1 output'

    $bootstrapOperations = @(Get-Content -LiteralPath $markerPath | Where-Object { $_ })
    Assert-True ($bootstrapOperations -contains 'installer_args=--quiet') 'Bootstrap installer is run with quiet switch'
    Assert-True ($bootstrapOperations -contains 'query') 'Endpoint updater queries Fusion after bootstrap install'
    Assert-True (Test-Path -LiteralPath $logPath) 'Endpoint updater writes durable status log'
    if (Test-Path -LiteralPath $logPath) {
        $logText = Get-Content -LiteralPath $logPath -Raw
        Assert-True ($logText -like '*FMU_STEP bootstrap_install_success*') 'Durable status log records bootstrap install success'
    }
    $remainingInstallers = @(Get-ChildItem -LiteralPath $tempRoot -Filter 'FusionAdminInstall-*' -File)
    Assert-Equal $remainingInstallers.Count 0 'Endpoint updater deletes downloaded bootstrap installer after install'
}
finally {
    $env:FMU_TEST_MARKER = $previousMarker
    $env:FMU_TEST_WEBDEPLOY_ROOT = $previousWebDeployRoot
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}

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
