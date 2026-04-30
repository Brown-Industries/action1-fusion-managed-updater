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

    $description = New-HistoricalVersionWarning -BuildVersion $BuildVersion -DetectedDate $DetectedDate
    [ordered]@{
        version                 = $BuildVersion
        app_name_match          = '^Autodesk Fusion(?: 360)?$'
        description             = $description
        internal_notes          = $description
        release_date            = $DetectedDate
        security_severity       = 'Unspecified'
        silent_install_switches = ''
        success_exit_codes      = '0'
        reboot_exit_codes       = ''
        install_type            = 'exe'
        update_type             = 'Regular Updates'
        os                      = @('Windows 10', 'Windows 11')
        file_name               = @{ Windows_64 = @{ name = $PayloadFileName; type = 'cloud' } }
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

Export-ModuleMember -Function ConvertTo-FusionVersionParts, Compare-FusionVersion, Read-FusionInfoFile, Get-HighestFusionInventoryVersion, New-HistoricalVersionWarning, New-Action1FusionVersionBody, Test-AutodeskHeadChanged, New-FusionWatcherDryRunResult, Get-AutodeskInstallerHead, ConvertFrom-AutodeskInstallerHeadRecord, Get-LatestFusionStreamer, Get-FusionBlockingProcesses
