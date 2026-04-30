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

    $versions = @()
    foreach ($item in $Inventory.items) {
        $name = [string]$item.fields.Name
        $version = [string]$item.fields.Version
        if ($name -match '^Autodesk Fusion(?: 360)?$' -and $version) {
            $versions += $version
        }
    }
    if ($versions.Count -eq 0) { return $null }
    $highest = $versions[0]
    foreach ($version in $versions) {
        if ((Compare-FusionVersion -Left $version -Right $highest) -gt 0) {
            $highest = $version
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

function Get-AutodeskInstallerHead {
    param([Parameter(Mandatory = $true)][string]$Url)

    $response = Invoke-WebRequest -Uri $Url -Method Head -MaximumRedirection 5 -UseBasicParsing -TimeoutSec 60
    [pscustomobject]@{
        Url           = $Url
        LastModified  = ($response.Headers['Last-Modified'] -join ',')
        ETag          = ($response.Headers['ETag'] -join ',')
        ContentLength = ($response.Headers['Content-Length'] -join ',')
    }
}

Export-ModuleMember -Function ConvertTo-FusionVersionParts, Compare-FusionVersion, Read-FusionInfoFile, Get-HighestFusionInventoryVersion, New-HistoricalVersionWarning, Get-AutodeskInstallerHead
