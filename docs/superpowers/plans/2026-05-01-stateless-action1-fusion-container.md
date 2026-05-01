# Stateless Action1 Fusion Container Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a stateless Docker container that authenticates to Action1, finds or creates the Fusion custom package by name, records missing Fusion versions, uploads the small Windows payload, and can run once or on a recurring schedule.

**Architecture:** Keep the Windows endpoint updater unchanged and add a portable admin-side automation path. Put reusable Action1 HTTP/package/upload functions in a focused module, drive one stateless sync script from environment variables, and wrap it with a container entrypoint for one-shot or recurring execution.

**Tech Stack:** PowerShell 7 (`pwsh`), Action1 REST API, Docker Linux PowerShell image, Debian cron for standard cron expressions, existing plain PowerShell test runner.

---

## File Structure

- Modify `src/FusionManagedUpdate.Common.psm1`
  - Add reusable container configuration parsing.
  - Add package-body creation for the auto-created Action1 package.
  - Add helpers for finding version records and binary attachment status.
- Create `src/Action1Repository.psm1`
  - Own Action1 OAuth, JSON API calls, package lookup/create, version create, and payload upload.
  - Keep HTTP details out of the watcher and endpoint updater scripts.
- Create `src/Invoke-FusionAction1RepositorySync.ps1`
  - Execute one stateless sync run.
  - Use Action1 as source of truth; no state file.
  - Support offline fixtures for tests.
- Create `container/entrypoint.ps1`
  - Parse `ONE_SHOT`, `CHECK_FREQUENCY_CRON`, and `CHECK_FREQUENCY_MINUTES`.
  - Run once by default.
  - Run once then schedule when `ONE_SHOT=false`.
- Create `Dockerfile`
  - Build payload during image build.
  - Install cron.
  - Set PowerShell entrypoint.
- Create `docker-compose.example.yml`
  - Show required credential variables and optional schedule variables.
- Create `.dockerignore`
  - Keep generated, git, and local state files out of Docker build context.
- Modify `tests/FusionManagedUpdate.Tests.ps1`
  - Add tests for config parsing, package lookup, idempotency, upload repair, and new scripts.
  - Use `pwsh` when available so tests are portable.
- Modify `README.md`
  - Document stateless container mode and environment variables.
- Modify `action1/validation-notes.md`
  - Record that the container auto-discovers or creates the package by display name.

## Task 1: Make Tests PowerShell-Host Portable

**Files:**
- Modify: `tests/FusionManagedUpdate.Tests.ps1`

- [ ] **Step 1: Write the failing test/helper change**

Add this helper near the top of `tests/FusionManagedUpdate.Tests.ps1` after path variables:

```powershell
function Get-TestPowerShellCommand {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) { return $pwsh.Source }
    return 'powershell.exe'
}

$testPowerShell = Get-TestPowerShellCommand

Assert-True (-not [string]::IsNullOrWhiteSpace($testPowerShell)) 'Test runner resolves a PowerShell executable'
```

Replace each direct `powershell.exe` invocation in helper functions with `$testPowerShell`.

- [ ] **Step 2: Run tests to verify the changed test harness still works**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

Expected: tests pass on Windows. On Linux, the same test file will select `pwsh`.

- [ ] **Step 3: Commit**

```powershell
git add tests/FusionManagedUpdate.Tests.ps1
git commit -m "test: support pwsh in Fusion updater tests"
```

## Task 2: Add Container Config And Package Body Helpers

**Files:**
- Modify: `src/FusionManagedUpdate.Common.psm1`
- Modify: `tests/FusionManagedUpdate.Tests.ps1`

- [ ] **Step 1: Write failing tests**

Add tests after the historical warning/package body tests:

```powershell
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

Expected: fail because `Get-FusionContainerRuntimeConfig` and `New-Action1FusionPackageBody` do not exist.

- [ ] **Step 3: Implement helpers**

Add to `src/FusionManagedUpdate.Common.psm1`:

```powershell
function Get-FusionSettingValue {
    param(
        [hashtable]$Environment,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Default = ''
    )

    if ($Environment -and $Environment.ContainsKey($Name)) {
        return [string]$Environment[$Name]
    }

    $value = [Environment]::GetEnvironmentVariable($Name)
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
```

Add the new exported functions to `Export-ModuleMember`.

- [ ] **Step 4: Run tests to verify pass**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```powershell
git add src/FusionManagedUpdate.Common.psm1 tests/FusionManagedUpdate.Tests.ps1
git commit -m "feat: add Fusion container runtime config"
```

## Task 3: Add Action1 Repository API Module

**Files:**
- Create: `src/Action1Repository.psm1`
- Modify: `tests/FusionManagedUpdate.Tests.ps1`

- [ ] **Step 1: Import the new module in tests**

Near the existing common module import, add:

```powershell
$action1ModulePath = Join-Path $repoRoot 'src/Action1Repository.psm1'
if (Test-Path -LiteralPath $action1ModulePath) {
    Import-Module $action1ModulePath -Force
}
```

- [ ] **Step 2: Write failing tests for pure request helpers and package selection**

Add tests after the config tests:

```powershell
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
Assert-Equal $noPackage $null 'Package selector returns null for no exact package'

$duplicatePackages = [pscustomobject]@{
    items = @(
        [pscustomobject]@{ id = 'pkg-1'; name = 'Autodesk Fusion Managed Updater'; builtin = 'no' },
        [pscustomobject]@{ id = 'pkg-2'; name = 'autodesk fusion managed updater'; builtin = 'no' }
    )
}
Assert-ThrowsLike {
    Select-Action1PackageByExactName -Packages $duplicatePackages -PackageName 'Autodesk Fusion Managed Updater'
} '*Multiple Action1 packages*' 'Package selector rejects duplicate exact names'
```

- [ ] **Step 3: Run tests to verify they fail**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

Expected: fail because `src/Action1Repository.psm1` and its functions do not exist.

- [ ] **Step 4: Implement initial Action1 module**

Create `src/Action1Repository.psm1`:

```powershell
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

Export-ModuleMember -Function New-Action1TokenRequestBody, Select-Action1PackageByExactName, Get-Action1AccessToken, Invoke-Action1JsonApi
```

- [ ] **Step 5: Run tests to verify pass**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```powershell
git add src/Action1Repository.psm1 tests/FusionManagedUpdate.Tests.ps1
git commit -m "feat: add Action1 repository API helpers"
```

## Task 4: Add Package Ensure And Version Record Helpers

**Files:**
- Modify: `src/Action1Repository.psm1`
- Modify: `src/FusionManagedUpdate.Common.psm1`
- Modify: `tests/FusionManagedUpdate.Tests.ps1`

- [ ] **Step 1: Write failing tests for version binary state**

Add after package version helper tests:

```powershell
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

$packageWithoutBinary = [pscustomobject]@{
    versions = @(
        [pscustomobject]@{ id = 'version-1'; version = '2702.1.58' }
    )
}
$missingBinaryRecord = Get-Action1PackageVersionRecord -Package $packageWithoutBinary -BuildVersion '2702.1.58'
Assert-True (-not (Test-Action1PackageVersionHasWindowsBinary -VersionRecord $missingBinaryRecord)) 'Version binary helper reports missing Windows binary'
```

- [ ] **Step 2: Write failing tests for ensure package behavior**

Add after Action1 module tests:

```powershell
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
$createdPackage = Ensure-Action1PackageByName -BaseUrl 'https://action1.invalid/api/3.0' -OrgId 'all' -AccessToken 'token' -PackageName 'Autodesk Fusion Managed Updater' -RequestCommand {
    param($Method, $Path, $Body)
    $script:createdPackageCalls += "$Method $Path"
    if ($Method -eq 'GET') { return [pscustomobject]@{ items = @() } }
    if ($Method -eq 'POST') { return [pscustomobject]@{ id = 'pkg-new'; name = $Body.name } }
}
Assert-Equal $createdPackage.id 'pkg-new' 'Ensure package creates missing package'
Assert-True (($createdPackageCalls -join ',') -like '*POST /software-repository/all*') 'Ensure package posts missing package'
```

- [ ] **Step 3: Run tests to verify they fail**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

Expected: fail because helper functions are missing.

- [ ] **Step 4: Implement version binary helpers**

Add to `src/FusionManagedUpdate.Common.psm1`:

```powershell
function Get-Action1PackageVersionRecord {
    param(
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)][string]$BuildVersion
    )

    foreach ($record in (Get-Action1PackageVersionRecords -Package $Package)) {
        $versionProperty = $record.PSObject.Properties['version']
        if ($versionProperty -and ([string]$versionProperty.Value) -eq $BuildVersion) {
            return $record
        }
    }
    return $null
}

function Test-Action1PackageVersionHasWindowsBinary {
    param($VersionRecord)

    if ($null -eq $VersionRecord) { return $false }
    $binaryProperty = $VersionRecord.PSObject.Properties['binary_id']
    if (-not $binaryProperty) { return $false }
    $windowsBinary = $binaryProperty.Value.PSObject.Properties['Windows_64']
    return $windowsBinary -and -not [string]::IsNullOrWhiteSpace([string]$windowsBinary.Value)
}
```

Add both functions to `Export-ModuleMember`.

- [ ] **Step 5: Implement ensure package helper**

Add to `src/Action1Repository.psm1`:

```powershell
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
```

Import `FusionManagedUpdate.Common.psm1` at the top of `src/Action1Repository.psm1`:

```powershell
$commonModulePath = Join-Path $PSScriptRoot 'FusionManagedUpdate.Common.psm1'
Import-Module $commonModulePath -Force
```

Export `Ensure-Action1PackageByName`.

- [ ] **Step 6: Run tests to verify pass**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```powershell
git add src/FusionManagedUpdate.Common.psm1 src/Action1Repository.psm1 tests/FusionManagedUpdate.Tests.ps1
git commit -m "feat: ensure Action1 Fusion package by name"
```

## Task 5: Add Version Create And Payload Upload Helpers

**Files:**
- Modify: `src/Action1Repository.psm1`
- Modify: `tests/FusionManagedUpdate.Tests.ps1`

- [ ] **Step 1: Write failing tests for upload headers**

Add after ensure package tests:

```powershell
$uploadHeaders = New-Action1UploadInitHeaders -AccessToken 'token' -PayloadLength 123
Assert-Equal $uploadHeaders.Authorization 'Bearer token' 'Upload init includes bearer token'
Assert-Equal $uploadHeaders.'X-Upload-Content-Type' 'application/octet-stream' 'Upload init sets content type header'
Assert-Equal $uploadHeaders.'X-Upload-Content-Length' '123' 'Upload init sets content length header'

$putHeaders = New-Action1UploadPutHeaders -AccessToken 'token' -PayloadLength 123
Assert-Equal $putHeaders.Authorization 'Bearer token' 'Upload PUT includes bearer token'
Assert-Equal $putHeaders.'Content-Range' 'bytes 0-122/123' 'Upload PUT sets content range'
```

- [ ] **Step 2: Write failing tests for stateless upload repair decision**

Add:

```powershell
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
```

- [ ] **Step 3: Run tests to verify they fail**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

Expected: fail because upload and sync action helpers do not exist.

- [ ] **Step 4: Implement upload and action helpers**

Add to `src/Action1Repository.psm1`:

```powershell
function New-Action1UploadInitHeaders {
    param(
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [Parameter(Mandatory = $true)][long]$PayloadLength
    )

    @{
        Authorization             = "Bearer $AccessToken"
        'X-Upload-Content-Type'   = 'application/octet-stream'
        'X-Upload-Content-Length' = [string]$PayloadLength
    }
}

function New-Action1UploadPutHeaders {
    param(
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [Parameter(Mandatory = $true)][long]$PayloadLength
    )

    @{
        Authorization   = "Bearer $AccessToken"
        'Content-Range' = "bytes 0-$($PayloadLength - 1)/$PayloadLength"
    }
}

function Resolve-Action1VersionSyncAction {
    param(
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)][string]$BuildVersion
    )

    $record = Get-Action1PackageVersionRecord -Package $Package -BuildVersion $BuildVersion
    if ($null -eq $record) { return 'CreateAndUpload' }
    if (Test-Action1PackageVersionHasWindowsBinary -VersionRecord $record) { return 'NoOp' }
    return 'UploadMissingBinary'
}

function New-Action1RepositoryVersion {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$OrgId,
        [Parameter(Mandatory = $true)][string]$PackageId,
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [Parameter(Mandatory = $true)]$Body
    )

    return Invoke-Action1JsonApi -Method 'POST' -BaseUrl $BaseUrl -AccessToken $AccessToken -Path "/software-repository/$OrgId/$PackageId/versions" -Body $Body
}

function Send-Action1VersionPayload {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$OrgId,
        [Parameter(Mandatory = $true)][string]$PackageId,
        [Parameter(Mandatory = $true)][string]$VersionId,
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [Parameter(Mandatory = $true)][string]$PayloadPath
    )

    $payloadBytes = [IO.File]::ReadAllBytes($PayloadPath)
    $initUri = "$($BaseUrl.TrimEnd('/'))/software-repository/$OrgId/$PackageId/versions/$VersionId/upload?platform=Windows_64"
    $initResponse = Invoke-WebRequest -Method Post -Uri $initUri -Headers (New-Action1UploadInitHeaders -AccessToken $AccessToken -PayloadLength $payloadBytes.Length) -ContentType 'application/json' -Body '{}' -SkipHttpErrorCheck
    $uploadLocation = [string]($initResponse.Headers['X-Upload-Location'] | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($uploadLocation)) {
        throw 'Action1 upload initialization did not return X-Upload-Location.'
    }

    Invoke-WebRequest -Method Put -Uri $uploadLocation -Headers (New-Action1UploadPutHeaders -AccessToken $AccessToken -PayloadLength $payloadBytes.Length) -ContentType 'application/octet-stream' -Body $payloadBytes | Out-Null
}
```

Export the new functions.

- [ ] **Step 5: Run tests to verify pass**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```powershell
git add src/Action1Repository.psm1 tests/FusionManagedUpdate.Tests.ps1
git commit -m "feat: add Action1 version upload helpers"
```

## Task 6: Add Stateless One-Run Sync Script

**Files:**
- Create: `src/Invoke-FusionAction1RepositorySync.ps1`
- Modify: `tests/FusionManagedUpdate.Tests.ps1`

- [ ] **Step 1: Add test helper for sync script**

Add path variable near other script paths:

```powershell
$syncScript = Join-Path $repoRoot 'src/Invoke-FusionAction1RepositorySync.ps1'
```

Add helper:

```powershell
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
```

- [ ] **Step 2: Write failing tests for no-op and create/upload flows**

Add after watcher live tests:

```powershell
$syncTempRoot = Join-Path $env:TEMP ('fmu-sync-test-' + [guid]::NewGuid().ToString('N'))
$previousAction1ClientId = $env:ACTION1_CLIENT_ID
$previousAction1ClientSecret = $env:ACTION1_CLIENT_SECRET
$previousPackageName = $env:PACKAGE_NAME
try {
    New-Item -ItemType Directory -Path $syncTempRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $syncTempRoot 'token.json') -Encoding ASCII -Value '{"access_token":"offline-token"}'
    Set-Content -LiteralPath (Join-Path $syncTempRoot 'packages.json') -Encoding ASCII -Value '{"items":[{"id":"pkg-1","name":"Autodesk Fusion Managed Updater"}]}'
    Set-Content -LiteralPath (Join-Path $syncTempRoot 'installed-software.json') -Encoding ASCII -Value ($inventory | ConvertTo-Json -Depth 20 -Compress)
    Set-Content -LiteralPath (Join-Path $syncTempRoot 'package.json') -Encoding ASCII -Value '{"id":"pkg-1","versions":[{"id":"version-1","version":"2702.1.58","binary_id":{"Windows_64":"binary-1"}}]}'

    $env:ACTION1_CLIENT_ID = 'client-id'
    $env:ACTION1_CLIENT_SECRET = 'client-secret'
    $env:PACKAGE_NAME = 'Autodesk Fusion Managed Updater'

    $noOpResult = Invoke-SyncScript -Arguments @('-OfflineFixtureRoot', $syncTempRoot, '-PayloadPath', (Join-Path $repoRoot 'dist/FusionManagedUpdater.cmd'))
    Assert-Equal $noOpResult.ExitCode 0 'Stateless sync exits 0 when version is already recorded'
    Assert-True ($noOpResult.Output -like '*already recorded*') 'Stateless sync reports already-recorded version'

    Set-Content -LiteralPath (Join-Path $syncTempRoot 'package.json') -Encoding ASCII -Value '{"id":"pkg-1","versions":[]}'
    Remove-Item -LiteralPath (Join-Path $syncTempRoot 'api-requests.log') -ErrorAction SilentlyContinue
    $createResult = Invoke-SyncScript -Arguments @('-OfflineFixtureRoot', $syncTempRoot, '-PayloadPath', (Join-Path $repoRoot 'dist/FusionManagedUpdater.cmd'))
    Assert-Equal $createResult.ExitCode 0 'Stateless sync exits 0 after creating and uploading missing version'
    Assert-True ($createResult.Output -like '*Created Action1 Fusion history version for 2702.1.58*') 'Stateless sync reports created version'
}
finally {
    if ($null -eq $previousAction1ClientId) { Remove-Item Env:\ACTION1_CLIENT_ID -ErrorAction SilentlyContinue } else { $env:ACTION1_CLIENT_ID = $previousAction1ClientId }
    if ($null -eq $previousAction1ClientSecret) { Remove-Item Env:\ACTION1_CLIENT_SECRET -ErrorAction SilentlyContinue } else { $env:ACTION1_CLIENT_SECRET = $previousAction1ClientSecret }
    if ($null -eq $previousPackageName) { Remove-Item Env:\PACKAGE_NAME -ErrorAction SilentlyContinue } else { $env:PACKAGE_NAME = $previousPackageName }
    if (Test-Path -LiteralPath $syncTempRoot) { Remove-Item -LiteralPath $syncTempRoot -Recurse -Force }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\packaging\build-action1-payload.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

Expected: fail because `Invoke-FusionAction1RepositorySync.ps1` does not exist.

- [ ] **Step 4: Implement sync script**

Create `src/Invoke-FusionAction1RepositorySync.ps1`:

```powershell
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
    $PayloadPath = Join-Path $PSScriptRoot '..\dist\FusionManagedUpdater.cmd'
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

$buildVersion = Resolve-FusionWatcherBuildVersion -Inventory $inventory
$syncAction = Resolve-Action1VersionSyncAction -Package $packageDetails -BuildVersion $buildVersion

if ($syncAction -eq 'NoOp') {
    Write-Host "Action1 Fusion history version for $buildVersion is already recorded with an uploaded payload."
    exit 0
}

if ($syncAction -eq 'CreateAndUpload') {
    $body = New-Action1FusionVersionBody -BuildVersion $buildVersion -DetectedDate (Get-Date).ToString('yyyy-MM-dd') -PayloadFileName 'FusionManagedUpdater.cmd'
    if ($OfflineFixtureRoot) {
        Write-OfflineRequest -Line "POST /software-repository/$($config.Action1OrgId)/$($package.id)/versions"
        $createdVersion = [pscustomobject]@{ id = "$($buildVersion)_offline"; version = $buildVersion }
    }
    else {
        $createdVersion = New-Action1RepositoryVersion -BaseUrl $config.Action1BaseUrl -OrgId $config.Action1OrgId -PackageId $package.id -AccessToken $accessToken -Body $body
    }
    $versionId = $createdVersion.id
}
else {
    $existingRecord = Get-Action1PackageVersionRecord -Package $packageDetails -BuildVersion $buildVersion
    $versionId = $existingRecord.id
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
```

- [ ] **Step 5: Run tests to verify pass**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\packaging\build-action1-payload.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```powershell
git add src/Invoke-FusionAction1RepositorySync.ps1 tests/FusionManagedUpdate.Tests.ps1
git commit -m "feat: add stateless Fusion Action1 sync"
```

## Task 7: Add Container Entrypoint Scheduler

**Files:**
- Create: `container/entrypoint.ps1`
- Modify: `tests/FusionManagedUpdate.Tests.ps1`

- [ ] **Step 1: Write failing tests for scheduler command generation**

Add tests after config tests:

```powershell
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

Expected: fail because `New-FusionContainerScheduleCommand` does not exist.

- [ ] **Step 3: Implement schedule command helper**

Add to `src/FusionManagedUpdate.Common.psm1`:

```powershell
function New-FusionContainerScheduleCommand {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$SyncScriptPath
    )

    $command = "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$SyncScriptPath`""
    if (-not [string]::IsNullOrWhiteSpace([string]$Config.CheckFrequencyCron)) {
        return [pscustomobject]@{
            Kind       = 'Cron'
            Expression = [string]$Config.CheckFrequencyCron
            Command    = $command
        }
    }

    return [pscustomobject]@{
        Kind    = 'Interval'
        Seconds = [int]$Config.CheckFrequencyMinutes * 60
        Command = $command
    }
}
```

Export the helper.

- [ ] **Step 4: Create container entrypoint**

Create `container/entrypoint.ps1`:

```powershell
#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [string]$SyncScriptPath = '/app/src/Invoke-FusionAction1RepositorySync.ps1'
)

$ErrorActionPreference = 'Stop'

Import-Module '/app/src/FusionManagedUpdate.Common.psm1' -Force

$config = Get-FusionContainerRuntimeConfig
$schedule = New-FusionContainerScheduleCommand -Config $config -SyncScriptPath $SyncScriptPath

function Invoke-SyncOnce {
    param([Parameter(Mandatory = $true)][string]$ScriptPath)
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $ScriptPath
}

Invoke-SyncOnce -ScriptPath $SyncScriptPath

if ($config.OneShot) {
    exit 0
}

if ($schedule.Kind -eq 'Interval') {
    while ($true) {
        Start-Sleep -Seconds $schedule.Seconds
        try {
            Invoke-SyncOnce -ScriptPath $SyncScriptPath
        }
        catch {
            Write-Error $_
        }
    }
}

$envFile = '/etc/action1-fusion-container.env'
Get-ChildItem Env: | ForEach-Object {
    $escaped = $_.Value.Replace("'", "'\''")
    "$($_.Name)='$escaped'"
} | Set-Content -LiteralPath $envFile -Encoding ASCII

$runner = '/usr/local/bin/action1-fusion-sync.sh'
@(
    '#!/usr/bin/env bash'
    'set -a'
    ". $envFile"
    'set +a'
    $schedule.Command
) | Set-Content -LiteralPath $runner -Encoding ASCII
chmod +x $runner

$cronFile = '/etc/cron.d/action1-fusion-sync'
"$($schedule.Expression) root $runner >> /proc/1/fd/1 2>> /proc/1/fd/2" | Set-Content -LiteralPath $cronFile -Encoding ASCII
chmod 0644 $cronFile

& /usr/sbin/cron -f
```

- [ ] **Step 5: Run tests to verify pass**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```powershell
git add src/FusionManagedUpdate.Common.psm1 container/entrypoint.ps1 tests/FusionManagedUpdate.Tests.ps1
git commit -m "feat: add Fusion container scheduler entrypoint"
```

## Task 8: Add Docker Artifacts

**Files:**
- Create: `Dockerfile`
- Create: `docker-compose.example.yml`
- Create: `.dockerignore`

- [ ] **Step 1: Add `.dockerignore`**

Create `.dockerignore`:

```text
.git
.worktrees
dist/*.cmd
state
*.log
```

- [ ] **Step 2: Add Dockerfile**

Create `Dockerfile`:

```dockerfile
FROM mcr.microsoft.com/powershell:7.4-ubuntu-22.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends cron ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY src/ ./src/
COPY packaging/ ./packaging/
COPY container/ ./container/

RUN pwsh -NoProfile -ExecutionPolicy Bypass -File ./packaging/build-action1-payload.ps1

ENTRYPOINT ["pwsh", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "/app/container/entrypoint.ps1"]
```

- [ ] **Step 3: Add Compose example**

Create `docker-compose.example.yml`:

```yaml
services:
  fusion-action1-updater:
    build: .
    environment:
      ACTION1_CLIENT_ID: "${ACTION1_CLIENT_ID}"
      ACTION1_CLIENT_SECRET: "${ACTION1_CLIENT_SECRET}"
      PACKAGE_NAME: "Autodesk Fusion Managed Updater"
      ACTION1_ORG_ID: "all"
      ONE_SHOT: "true"
      CHECK_FREQUENCY_MINUTES: "1440"
```

- [ ] **Step 4: Build image locally**

Run:

```powershell
docker build -t action1-fusion-managed-updater:local .
```

Expected: image builds and the Dockerfile reports payload generation.

- [ ] **Step 5: Run one-shot config failure smoke test**

Run:

```powershell
docker run --rm action1-fusion-managed-updater:local
```

Expected: exits nonzero and reports `ACTION1_CLIENT_ID is required.`

- [ ] **Step 6: Commit**

```powershell
git add .dockerignore Dockerfile docker-compose.example.yml
git commit -m "feat: add Docker packaging for Fusion Action1 sync"
```

## Task 9: Update Documentation

**Files:**
- Modify: `README.md`
- Modify: `action1/validation-notes.md`

- [ ] **Step 1: Update README container section**

Add this section to `README.md` after Live Watcher Environment:

````markdown
## Stateless Docker Container

The Docker image runs the Action1 repository automation from a Linux container. It does not require a mounted state volume. Action1 is the durable source of truth: if the package version already exists and has an uploaded Windows payload, the run exits successfully.

Required environment variables:

```text
ACTION1_CLIENT_ID=<Action1 OAuth client id>
ACTION1_CLIENT_SECRET=<Action1 OAuth client secret>
```

Optional environment variables:

```text
ACTION1_BASE_URL=https://app.action1.com/api/3.0
ACTION1_ORG_ID=all
PACKAGE_NAME=Autodesk Fusion Managed Updater
ONE_SHOT=true
CHECK_FREQUENCY_CRON=
CHECK_FREQUENCY_MINUTES=1440
```

Build:

```powershell
docker build -t action1-fusion-managed-updater:local .
```

Run once:

```powershell
docker run --rm `
  -e ACTION1_CLIENT_ID="$env:ACTION1_CLIENT_ID" `
  -e ACTION1_CLIENT_SECRET="$env:ACTION1_CLIENT_SECRET" `
  action1-fusion-managed-updater:local
```

Run continuously with a daily interval:

```yaml
services:
  fusion-action1-updater:
    image: action1-fusion-managed-updater:local
    environment:
      ACTION1_CLIENT_ID: "${ACTION1_CLIENT_ID}"
      ACTION1_CLIENT_SECRET: "${ACTION1_CLIENT_SECRET}"
      ONE_SHOT: "false"
      CHECK_FREQUENCY_MINUTES: "1440"
```

`PACKAGE_NAME` is the Action1 custom package display name. The container finds or creates that package. Fusion software detection still uses the package version match regex `^Autodesk Fusion(?: 360)?$`.
````

- [ ] **Step 2: Update validation notes**

Add a short note to `action1/validation-notes.md`:

```markdown
## Container Automation

The container path discovers the Action1 package by `PACKAGE_NAME`. If no exact package name exists, it creates the package with the same package-level warning text validated above. Operators only need Action1 API credentials for initial setup.
```

- [ ] **Step 3: Run markdown and whitespace checks**

Run:

```powershell
git diff --check
```

Expected: no output.

- [ ] **Step 4: Commit**

```powershell
git add README.md action1/validation-notes.md
git commit -m "docs: document stateless Fusion Action1 container"
```

## Task 10: Final Verification

**Files:**
- Verify all changed files.

- [ ] **Step 1: Run full PowerShell tests**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

Expected: all tests pass.

- [ ] **Step 2: Rebuild payload**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\packaging\build-action1-payload.ps1
```

Expected: writes `dist\FusionManagedUpdater.cmd` and reports a size under 1 MB.

- [ ] **Step 3: Build Docker image**

Run:

```powershell
docker build -t action1-fusion-managed-updater:local .
```

Expected: image builds successfully.

- [ ] **Step 4: Run Docker config smoke test**

Run:

```powershell
docker run --rm action1-fusion-managed-updater:local
```

Expected: exits nonzero with `ACTION1_CLIENT_ID is required.`

- [ ] **Step 5: Check diff hygiene**

Run:

```powershell
git diff --check
git status --short
```

Expected: no whitespace errors; only expected ignored generated files such as `dist/FusionManagedUpdater.cmd`.

- [ ] **Step 6: Final commit if previous tasks left changes**

```powershell
git add .
git commit -m "chore: verify stateless Fusion Action1 container"
```

Skip this commit when there are no tracked changes.

## Self-Review

- Spec coverage: this plan covers stateless behavior, Action1 credentials, package-name discovery/create, one-shot default, long-running interval/cron mode, version no-op, missing-binary repair, Docker artifacts, and documentation.
- Placeholder scan: the plan uses concrete paths, function names, commands, and environment variable names.
- Type consistency: package helpers use `PackageName`, Action1 API helpers use `BaseUrl`, `OrgId`, `AccessToken`, `PackageId`, and version helpers use `BuildVersion` consistently.
