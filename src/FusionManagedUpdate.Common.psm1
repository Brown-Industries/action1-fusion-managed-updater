function ConvertTo-FusionVersionParts {
    param([Parameter(Mandatory = $true)][string]$Version)

    $parts = $Version -split '\.'
    $numbers = @()
    foreach ($part in $parts) {
        $value = 0
        if (-not [int]::TryParse($part, [ref]$value)) {
            throw "Invalid Fusion version segment '$part' in '$Version'."
        }
        $numbers += $value
    }
    return $numbers
}

function Compare-FusionVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    $leftParts = @(ConvertTo-FusionVersionParts -Version $Left)
    $rightParts = @(ConvertTo-FusionVersionParts -Version $Right)
    $max = [Math]::Max($leftParts.Count, $rightParts.Count)
    for ($i = 0; $i -lt $max; $i++) {
        $l = if ($i -lt $leftParts.Count) { $leftParts[$i] } else { 0 }
        $r = if ($i -lt $rightParts.Count) { $rightParts[$i] } else { 0 }
        if ($l -gt $r) { return 1 }
        if ($l -lt $r) { return -1 }
    }
    return 0
}

function Read-FusionInfoFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Fusion info file was not created: $Path"
    }
    $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    [pscustomobject]@{
        BuildVersion           = $json.manifest.'build-version'
        MajorUpdateVersion     = $json.manifest.'major-update-version'
        ReleaseVersion         = $json.manifest.'release-version'
        StreamerFeatureVersion = $json.manifest.streamer.'feature-version'
        StreamerReleaseId      = $json.manifest.streamer.'release-id'
        DisplayName            = $json.manifest.properties.'display-name'
        InstallPath            = $json.install_path
        Connection             = $json.connection
        Stream                 = $json.stream
    }
}

function Get-HighestFusionInventoryVersion {
    param([Parameter(Mandatory = $true)]$Inventory)

    $highest = $null
    foreach ($item in $Inventory.items) {
        $name = [string]$item.fields.Name
        $version = [string]$item.fields.Version
        if ($name -match '^Autodesk Fusion(?: 360)?$' -and $version) {
            try {
                [void](ConvertTo-FusionVersionParts -Version $version)
                if ($null -eq $highest -or (Compare-FusionVersion -Left $version -Right $highest) -gt 0) {
                    $highest = $version
                }
            }
            catch {
                continue
            }
        }
    }
    return $highest
}

function New-HistoricalVersionWarning {
    param(
        [Parameter(Mandatory = $true)][string]$BuildVersion,
        [Parameter(Mandatory = $true)][string]$DetectedDate
    )

    return "This version records Autodesk Fusion build $BuildVersion as detected on $DetectedDate. Fusion is delivered by Autodesk's live streamer endpoint. Deploying this or any older version will update the endpoint to Autodesk's currently available Fusion build, not necessarily this historical build. Only the latest Autodesk-served Fusion build is installable through this package."
}

function New-Action1FusionVersionBody {
    param(
        [Parameter(Mandatory = $true)][string]$BuildVersion,
        [Parameter(Mandatory = $true)][string]$DetectedDate,
        [Parameter(Mandatory = $true)][string]$PayloadFileName
    )

    [ordered]@{
        version                 = $BuildVersion
        app_name_match          = '^Autodesk Fusion(?: 360)?$'
        release_date            = $DetectedDate
        security_severity       = 'Unspecified'
        silent_install_switches = $PayloadFileName
        success_exit_codes      = '0'
        reboot_exit_codes       = '1641,3010'
        install_type            = 'other'
        update_type             = 'Regular Updates'
        os                      = @('Windows 10', 'Windows 11')
        file_name               = @{ Windows_64 = @{ name = $PayloadFileName; type = 'cloud' } }
    }
}

function Get-FusionSettingValue {
    param(
        [hashtable]$Environment,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Default = ''
    )

    $value = $null
    if ($Environment -and $Environment.ContainsKey($Name)) {
        $value = [string]$Environment[$Name]
    }
    else {
        $value = [Environment]::GetEnvironmentVariable($Name)
    }

    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }
    return $value
}

function ConvertTo-FusionBooleanSetting {
    param(
        [string]$Value,
        [bool]$Default = $false,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Default
    }

    switch -Regex ($Value.Trim()) {
        '^(1|true|yes|y)$' { return $true }
        '^(0|false|no|n)$' { return $false }
        default { throw "$Name must be true or false." }
    }
}

function Get-FusionContainerRuntimeConfig {
    param([hashtable]$Environment = $null)

    $clientId = Get-FusionSettingValue -Environment $Environment -Name 'ACTION1_CLIENT_ID'
    $clientSecret = Get-FusionSettingValue -Environment $Environment -Name 'ACTION1_CLIENT_SECRET'
    if ([string]::IsNullOrWhiteSpace($clientId)) { throw 'ACTION1_CLIENT_ID is required.' }
    if ([string]::IsNullOrWhiteSpace($clientSecret)) { throw 'ACTION1_CLIENT_SECRET is required.' }

    $minutesText = Get-FusionSettingValue -Environment $Environment -Name 'CHECK_FREQUENCY_MINUTES' -Default '1440'
    $minutes = 0
    if (-not [int]::TryParse($minutesText, [ref]$minutes) -or $minutes -lt 1) {
        throw 'CHECK_FREQUENCY_MINUTES must be a positive integer.'
    }

    [pscustomobject]@{
        Action1ClientId       = $clientId
        Action1ClientSecret   = $clientSecret
        Action1BaseUrl        = (Get-FusionSettingValue -Environment $Environment -Name 'ACTION1_BASE_URL' -Default 'https://app.action1.com/api/3.0').TrimEnd('/')
        Action1OrgId          = Get-FusionSettingValue -Environment $Environment -Name 'ACTION1_ORG_ID' -Default 'all'
        PackageName           = Get-FusionSettingValue -Environment $Environment -Name 'PACKAGE_NAME' -Default 'Autodesk Fusion Managed Updater'
        OneShot               = ConvertTo-FusionBooleanSetting -Value (Get-FusionSettingValue -Environment $Environment -Name 'ONE_SHOT' -Default 'true') -Default $true -Name 'ONE_SHOT'
        CheckFrequencyCron    = Get-FusionSettingValue -Environment $Environment -Name 'CHECK_FREQUENCY_CRON'
        CheckFrequencyMinutes = $minutes
    }
}

function New-FusionContainerScheduleCommand {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$SyncScriptPath
    )

    $quotedSyncScriptPath = ConvertTo-FusionBashSingleQuotedArgument -Value $SyncScriptPath
    $command = "pwsh -NoProfile -ExecutionPolicy Bypass -File $quotedSyncScriptPath"
    if (-not [string]::IsNullOrWhiteSpace([string]$Config.CheckFrequencyCron)) {
        return [pscustomobject]@{
            Kind       = 'Cron'
            Expression = Assert-FusionContainerCronExpression -Expression ([string]$Config.CheckFrequencyCron)
            Command    = $command
        }
    }

    return [pscustomobject]@{
        Kind    = 'Interval'
        Seconds = [int]$Config.CheckFrequencyMinutes * 60
        Command = $command
    }
}

function ConvertTo-FusionBashSingleQuotedArgument {
    param([Parameter(Mandatory = $true)][string]$Value)

    return "'$($Value.Replace("'", "'\''"))'"
}

function Assert-FusionContainerCronExpression {
    param([Parameter(Mandatory = $true)][string]$Expression)

    if ([string]::IsNullOrWhiteSpace($Expression)) {
        throw 'CHECK_FREQUENCY_CRON must not be blank.'
    }

    if ($Expression -match '[\x00-\x1F\x7F]') {
        throw 'CHECK_FREQUENCY_CRON must not contain control characters.'
    }

    $fields = @($Expression.Trim() -split '\s+')
    if ($fields.Count -ne 5) {
        throw 'CHECK_FREQUENCY_CRON must contain exactly five fields.'
    }

    return $Expression
}

function New-FusionContainerCronEnvironmentSpec {
    param([hashtable]$Environment = $null)

    $names = @(
        'ACTION1_CLIENT_ID',
        'ACTION1_CLIENT_SECRET',
        'ACTION1_BASE_URL',
        'ACTION1_ORG_ID',
        'PACKAGE_NAME',
        'CHECK_FREQUENCY_CRON',
        'CHECK_FREQUENCY_MINUTES',
        'ONE_SHOT'
    )

    $lines = foreach ($name in $names) {
        $value = Get-FusionSettingValue -Environment $Environment -Name $name
        if ($null -ne $value) {
            $escaped = ([string]$value).Replace("'", "'\''")
            "$name='$escaped'"
        }
    }

    [pscustomobject]@{
        Mode  = '0600'
        Lines = @($lines)
    }
}

function Invoke-FusionContainerSyncOnce {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string]$PowerShellCommand = 'pwsh'
    )

    & $PowerShellCommand -NoProfile -ExecutionPolicy Bypass -File $ScriptPath
    $exitCode = $LASTEXITCODE
    if ($null -ne $exitCode -and $exitCode -ne 0) {
        throw "Fusion container sync script '$ScriptPath' exited with code $exitCode."
    }
}

function Invoke-FusionContainerStartupSync {
    param(
        [Parameter(Mandatory = $true)][bool]$OneShot,
        [Parameter(Mandatory = $true)][scriptblock]$SyncCommand,
        [scriptblock]$LogCommand = {
            param($ErrorRecord)
            Write-Error $ErrorRecord -ErrorAction Continue
        }
    )

    try {
        & $SyncCommand
        return [pscustomobject]@{
            Succeeded          = $true
            ContinueScheduling = $true
        }
    }
    catch {
        if ($OneShot) {
            throw
        }

        & $LogCommand $_
        return [pscustomobject]@{
            Succeeded          = $false
            ContinueScheduling = $true
        }
    }
}

function New-Action1FusionPackageBody {
    param([Parameter(Mandatory = $true)][string]$PackageName)

    [ordered]@{
        name           = $PackageName
        vendor         = 'Autodesk'
        description    = "Small Action1-managed updater for Autodesk Fusion. Historical versions are release records only; Autodesk's live streamer controls the actual installable build."
        platform       = 'Windows'
        internal_notes = "Do not use this package for rollback. Deployments run Autodesk's currently available Fusion streamer update."
    }
}

function Test-AutodeskHeadChanged {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$AutodeskHead
    )

    return ($State.ETag -ne $AutodeskHead.ETag) -or ($State.LastModified -ne $AutodeskHead.LastModified) -or ($State.ContentLength -ne $AutodeskHead.ContentLength)
}

function New-FusionWatcherDryRunResult {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$AutodeskHead,
        [Parameter(Mandatory = $true)][string]$BuildVersion,
        [Parameter(Mandatory = $true)][string]$DetectedDate,
        [Parameter(Mandatory = $true)][string]$PayloadFileName
    )

    [pscustomobject]@{
        Changed            = Test-AutodeskHeadChanged -State $State -AutodeskHead $AutodeskHead
        AutodeskHead       = $AutodeskHead
        Action1VersionBody = New-Action1FusionVersionBody -BuildVersion $BuildVersion -DetectedDate $DetectedDate -PayloadFileName $PayloadFileName
    }
}

function Assert-FusionWatcherLiveBuildVersion {
    param([string]$BuildVersion)

    if ([string]::IsNullOrWhiteSpace($BuildVersion) -or $BuildVersion -like 'unknown-*') {
        throw 'FUSION_OBSERVED_BUILD_VERSION must be set to a real observed Fusion build version for live Action1 version creation.'
    }
    try {
        $parts = @(ConvertTo-FusionVersionParts -Version $BuildVersion)
    }
    catch {
        throw 'FUSION_OBSERVED_BUILD_VERSION must be a numeric dotted Fusion build version for live Action1 version creation.'
    }
    if ($parts.Count -lt 2) {
        throw 'FUSION_OBSERVED_BUILD_VERSION must be a numeric dotted Fusion build version for live Action1 version creation.'
    }
    return $BuildVersion
}

function Resolve-FusionWatcherBuildVersion {
    param(
        [Parameter(Mandatory = $true)]$Inventory,
        [string]$ManualBuildVersion = '',
        [switch]$AllowManualObservedBuild
    )

    $manualBuild = if ($ManualBuildVersion) { $ManualBuildVersion.Trim() } else { '' }
    if ($AllowManualObservedBuild) {
        return Assert-FusionWatcherLiveBuildVersion -BuildVersion $manualBuild
    }

    $inventoryBuild = Get-HighestFusionInventoryVersion -Inventory $Inventory
    if ([string]::IsNullOrWhiteSpace($inventoryBuild)) {
        throw 'Action1 installed software inventory did not report an Autodesk Fusion build version. Refresh Action1 inventory before live version creation, or use -AllowManualObservedBuild with a verified FUSION_OBSERVED_BUILD_VERSION.'
    }

    if (-not [string]::IsNullOrWhiteSpace($manualBuild)) {
        [void](Assert-FusionWatcherLiveBuildVersion -BuildVersion $manualBuild)
        if ((Compare-FusionVersion -Left $manualBuild -Right $inventoryBuild) -ne 0) {
            throw "FUSION_OBSERVED_BUILD_VERSION '$manualBuild' does not match highest Action1 inventory version '$inventoryBuild'. Refresh Action1 inventory or use -AllowManualObservedBuild only after verifying the build outside Action1."
        }
    }

    return $inventoryBuild
}

function Test-Action1PackageVersionContainerPresent {
    param([Parameter(Mandatory = $true)]$Package)

    return $null -ne $Package.PSObject.Properties['versions']
}

function Get-Action1PackageVersionRecords {
    param([Parameter(Mandatory = $true)]$Package)

    $containers = @()
    foreach ($propertyName in @('versions', 'version')) {
        $property = $Package.PSObject.Properties[$propertyName]
        if ($property) {
            $containers += $property.Value
        }
    }

    $records = @()
    foreach ($container in $containers) {
        if ($null -eq $container) {
            continue
        }

        $nestedItems = $null
        foreach ($nestedName in @('items', 'data', 'results')) {
            $nestedProperty = $container.PSObject.Properties[$nestedName]
            if ($nestedProperty) {
                $nestedItems = $nestedProperty.Value
                break
            }
        }

        if ($null -ne $nestedItems) {
            $records += @($nestedItems)
        }
        else {
            $records += @($container)
        }
    }

    return $records
}

function Get-Action1PackageVersionValues {
    param([Parameter(Mandatory = $true)]$Package)

    $versions = @()
    foreach ($item in (Get-Action1PackageVersionRecords -Package $Package)) {
        if ($null -eq $item) {
            continue
        }
        if ($item -is [string]) {
            $versions += $item
            continue
        }

        $valueFound = $false
        foreach ($versionPropertyName in @('version')) {
            $versionProperty = $item.PSObject.Properties[$versionPropertyName]
            if ($versionProperty -and -not [string]::IsNullOrWhiteSpace([string]$versionProperty.Value)) {
                $versions += [string]$versionProperty.Value
                $valueFound = $true
                break
            }
        }
        if ($valueFound) {
            continue
        }

        $fieldsProperty = $item.PSObject.Properties['fields']
        if ($fieldsProperty) {
            $fieldVersion = $fieldsProperty.Value.PSObject.Properties['Version']
            if ($fieldVersion -and -not [string]::IsNullOrWhiteSpace([string]$fieldVersion.Value)) {
                $versions += [string]$fieldVersion.Value
            }
        }
    }

    return $versions
}

function Test-Action1PackageHasVersion {
    param(
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)][string]$BuildVersion
    )

    $versions = @(Get-Action1PackageVersionValues -Package $Package)
    return $versions -contains $BuildVersion
}

function Get-Action1PackageVersionRecord {
    param(
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)][string]$BuildVersion
    )

    foreach ($record in (Get-Action1PackageVersionRecords -Package $Package)) {
        if ($null -eq $record) {
            continue
        }
        $versionProperty = $record.PSObject.Properties['version']
        if ($versionProperty -and ([string]$versionProperty.Value) -eq $BuildVersion) {
            return $record
        }

        $fieldsProperty = $record.PSObject.Properties['fields']
        if ($fieldsProperty) {
            $fieldVersion = $fieldsProperty.Value.PSObject.Properties['Version']
            if ($fieldVersion -and ([string]$fieldVersion.Value) -eq $BuildVersion) {
                return $record
            }
        }
    }
    return $null
}

function Test-Action1PackageVersionHasWindowsBinary {
    param($VersionRecord)

    if ($null -eq $VersionRecord) { return $false }
    $binaryProperty = $VersionRecord.PSObject.Properties['binary_id']
    if (-not $binaryProperty) { return $false }
    if ($null -eq $binaryProperty.Value) { return $false }
    $windowsBinary = $binaryProperty.Value.PSObject.Properties['Windows_64']
    return $windowsBinary -and -not [string]::IsNullOrWhiteSpace([string]$windowsBinary.Value)
}

function Assert-FusionWatcherNewBuildNotAlreadyRecorded {
    param(
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)][string]$BuildVersion
    )

    if (Test-Action1PackageHasVersion -Package $Package -BuildVersion $BuildVersion) {
        throw "Action1 package already has Fusion version $BuildVersion. The Autodesk release signal changed, but Action1 inventory resolved to an already recorded build. Refresh Action1 inventory and rerun; watcher state was not updated."
    }

    return $BuildVersion
}

function Write-FusionWatcherState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$State
    )

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-AutodeskInstallerHead {
    param([Parameter(Mandatory = $true)][string]$Url)

    $response = Invoke-WebRequest -Uri $Url -Method Head -MaximumRedirection 5 -UseBasicParsing -TimeoutSec 60
    ConvertFrom-AutodeskInstallerHeadRecord -Record ([pscustomobject]@{
        Url           = $Url
        LastModified  = ($response.Headers['Last-Modified'] -join ',')
        ETag          = ($response.Headers['ETag'] -join ',')
        ContentLength = ($response.Headers['Content-Length'] -join ',')
    })
}

function ConvertFrom-AutodeskInstallerHeadRecord {
    param([Parameter(Mandatory = $true)]$Record)

    [pscustomobject]@{
        Url           = [string]$Record.Url
        LastModified  = [string]$Record.LastModified
        ETag          = [string]$Record.ETag
        ContentLength = [string]$Record.ContentLength
    }
}

function Get-LatestFusionStreamer {
    param([Parameter(Mandatory = $true)][string]$WebDeployRoot)
    $streamerRoot = Join-Path $WebDeployRoot 'meta\streamer'
    if (-not (Test-Path -LiteralPath $streamerRoot)) {
        throw "Fusion streamer directory was not found: $streamerRoot"
    }
    $candidate = Get-ChildItem -LiteralPath $streamerRoot -Directory |
        Sort-Object Name -Descending |
        ForEach-Object {
            $exe = Join-Path $_.FullName 'streamer.exe'
            if (Test-Path -LiteralPath $exe) { $exe }
        } |
        Select-Object -First 1
    if (-not $candidate) {
        throw "No streamer.exe was found under: $streamerRoot"
    }
    return $candidate
}

function Get-FusionBlockingProcesses {
    param($Processes = $null)

    if ($null -eq $Processes) {
        $Processes = Get-Process -ErrorAction SilentlyContinue
    }
    $names = @('Fusion360', 'FusionLauncher')
    return $Processes | Where-Object { $names -contains $_.ProcessName }
}

Export-ModuleMember -Function ConvertTo-FusionVersionParts, Compare-FusionVersion, Read-FusionInfoFile, Get-HighestFusionInventoryVersion, New-HistoricalVersionWarning, New-Action1FusionVersionBody, Get-FusionContainerRuntimeConfig, New-FusionContainerScheduleCommand, Assert-FusionContainerCronExpression, New-FusionContainerCronEnvironmentSpec, Invoke-FusionContainerSyncOnce, Invoke-FusionContainerStartupSync, New-Action1FusionPackageBody, Test-AutodeskHeadChanged, New-FusionWatcherDryRunResult, Assert-FusionWatcherLiveBuildVersion, Resolve-FusionWatcherBuildVersion, Test-Action1PackageVersionContainerPresent, Get-Action1PackageVersionRecords, Get-Action1PackageVersionValues, Test-Action1PackageHasVersion, Get-Action1PackageVersionRecord, Test-Action1PackageVersionHasWindowsBinary, Assert-FusionWatcherNewBuildNotAlreadyRecorded, Write-FusionWatcherState, Get-AutodeskInstallerHead, ConvertFrom-AutodeskInstallerHeadRecord, Get-LatestFusionStreamer, Get-FusionBlockingProcesses
