$commonModulePath = Join-Path $PSScriptRoot 'FusionManagedUpdate.Common.psm1'
Import-Module $commonModulePath

function ConvertTo-Action1FormValue {
    param([string]$Value)
    return [uri]::EscapeDataString($Value).Replace('%20', '+')
}

function New-Action1TokenRequestBody {
    param(
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$ClientSecret
    )

    return "grant_type=client_credentials&client_id=$(ConvertTo-Action1FormValue -Value $ClientId)&client_secret=$(ConvertTo-Action1FormValue -Value $ClientSecret)"
}

function Select-Action1PackageByExactName {
    param(
        [Parameter(Mandatory = $true)]$Packages,
        [Parameter(Mandatory = $true)][string]$PackageName
    )

    $matches = @($Packages.items | Where-Object {
        ([string]$_.name).Equals($PackageName, [System.StringComparison]::OrdinalIgnoreCase)
    })

    if ($matches.Count -gt 1) {
        throw "Multiple Action1 packages match PACKAGE_NAME '$PackageName'. Rename or remove duplicates before running automation."
    }
    if ($matches.Count -eq 0) {
        return $null
    }
    return $matches[0]
}

function Get-Action1AccessToken {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$ClientSecret
    )

    $tokenUrl = "$($BaseUrl.TrimEnd('/'))/oauth2/token"
    $response = Invoke-RestMethod -Method Post -Uri $tokenUrl -ContentType 'application/x-www-form-urlencoded' -Body (New-Action1TokenRequestBody -ClientId $ClientId -ClientSecret $ClientSecret)
    if ([string]::IsNullOrWhiteSpace([string]$response.access_token)) {
        throw 'Action1 token response did not include access_token.'
    }
    return [string]$response.access_token
}

function Invoke-Action1JsonApi {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST', 'PATCH')][string]$Method,
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [Parameter(Mandatory = $true)][string]$Path,
        [object]$Body = $null
    )

    $headers = @{ Authorization = "Bearer $AccessToken" }
    $uri = "$($BaseUrl.TrimEnd('/'))/$($Path.TrimStart('/'))"
    if ($null -ne $Body) {
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Depth 20)
    }
    return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
}

function Invoke-Action1RequestCommand {
    param(
        [scriptblock]$RequestCommand,
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        [object]$Body = $null,
        [string]$BaseUrl = '',
        [string]$AccessToken = ''
    )

    if ($RequestCommand) {
        return & $RequestCommand $Method $Path $Body
    }
    return Invoke-Action1JsonApi -Method $Method -BaseUrl $BaseUrl -AccessToken $AccessToken -Path $Path -Body $Body
}

function Ensure-Action1PackageByName {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$OrgId,
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [Parameter(Mandatory = $true)][string]$PackageName,
        [scriptblock]$RequestCommand = $null
    )

    $filter = [uri]::EscapeDataString($PackageName)
    $packages = Invoke-Action1RequestCommand -RequestCommand $RequestCommand -Method 'GET' -Path "/software-repository/$OrgId`?custom=yes&filter=$filter&fields=*&limit=100" -BaseUrl $BaseUrl -AccessToken $AccessToken
    $existing = Select-Action1PackageByExactName -Packages $packages -PackageName $PackageName
    if ($null -ne $existing) {
        return $existing
    }

    return Invoke-Action1RequestCommand -RequestCommand $RequestCommand -Method 'POST' -Path "/software-repository/$OrgId" -Body (New-Action1FusionPackageBody -PackageName $PackageName) -BaseUrl $BaseUrl -AccessToken $AccessToken
}

Export-ModuleMember -Function New-Action1TokenRequestBody, Select-Action1PackageByExactName, Get-Action1AccessToken, Invoke-Action1JsonApi, Ensure-Action1PackageByName
