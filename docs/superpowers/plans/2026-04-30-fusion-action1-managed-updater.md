# Fusion Action1 Managed Updater Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Windows-only Action1-managed Autodesk Fusion updater that keeps the Action1 package payload small while preserving Fusion release history in Action1 versions.

**Architecture:** The endpoint updater is a PowerShell script packaged into a single `.cmd` payload for Action1. The admin watcher is a PowerShell script that detects Autodesk release changes, builds the small payload, and creates Action1 Software Repository package versions whose descriptions clearly state that historical versions are audit records, not rollback installers.

**Tech Stack:** PowerShell 5.1-compatible scripts, built-in `Invoke-WebRequest`/`Invoke-RestMethod`, no Pester dependency, no Python dependency, Action1 REST API or Action1 MCP dry-runs for package validation.

---

## File Structure

- Create: `src/FusionManagedUpdate.Common.psm1`
  - Shared functions for version comparison, JSON parsing, logging, Action1 warning text, and Autodesk HEAD parsing.
- Create: `src/Invoke-FusionManagedUpdate.ps1`
  - Endpoint-side updater run by Action1. Finds all-users Fusion, queries current version, handles running processes, runs Autodesk streamer update, verifies post-update metadata.
- Create: `src/Watch-FusionAction1Release.ps1`
  - Admin-side watcher. Checks Autodesk release signals, reads/writes state, queries Action1 inventory, builds an Action1 version payload, and performs dry-run or live Action1 updates.
- Create: `packaging/build-action1-payload.ps1`
  - Generates `dist/FusionManagedUpdater.cmd`, a single-file launcher that writes the endpoint PowerShell script to temp and executes it.
- Create: `tests/run-tests.ps1`
  - No-dependency test runner.
- Create: `tests/FusionManagedUpdate.Tests.ps1`
  - Tests shared helper behavior and endpoint/watcher decision logic.
- Create: `tests/fixtures/fusioninfo-2702.1.47.json`
  - Minimal local Fusion query fixture.
- Create: `tests/fixtures/action1-installed-fusion.json`
  - Minimal Action1 inventory fixture with observed Fusion versions.
- Create: `tests/fixtures/autodesk-head-current.json`
  - Minimal Autodesk HEAD fixture.
- Create: `README.md`
  - Operator documentation for dry-run, Action1 credentials, package semantics, and deployment flow.

## Task 1: Test Harness And Fixtures

**Files:**
- Create: `tests/run-tests.ps1`
- Create: `tests/FusionManagedUpdate.Tests.ps1`
- Create: `tests/fixtures/fusioninfo-2702.1.47.json`
- Create: `tests/fixtures/action1-installed-fusion.json`
- Create: `tests/fixtures/autodesk-head-current.json`

- [ ] **Step 1: Create the failing test runner**

Create `tests/run-tests.ps1`:

```powershell
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$testFile = Join-Path $PSScriptRoot 'FusionManagedUpdate.Tests.ps1'

$script:Failures = 0

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)] $Actual,
        [Parameter(Mandatory = $true)] $Expected,
        [Parameter(Mandatory = $true)] [string] $Message
    )
    if ($Actual -ne $Expected) {
        $script:Failures++
        Write-Host "FAIL: $Message" -ForegroundColor Red
        Write-Host "  Expected: $Expected"
        Write-Host "  Actual:   $Actual"
    } else {
        Write-Host "PASS: $Message" -ForegroundColor Green
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)] [bool] $Condition,
        [Parameter(Mandatory = $true)] [string] $Message
    )
    if (-not $Condition) {
        $script:Failures++
        Write-Host "FAIL: $Message" -ForegroundColor Red
    } else {
        Write-Host "PASS: $Message" -ForegroundColor Green
    }
}

. $testFile

if ($script:Failures -gt 0) {
    Write-Host "$script:Failures test failure(s)." -ForegroundColor Red
    exit 1
}

Write-Host 'All tests passed.' -ForegroundColor Green
exit 0
```

- [ ] **Step 2: Create fixtures**

Create `tests/fixtures/fusioninfo-2702.1.47.json`:

```json
{
  "connection": "https://dl.appstreaming.autodesk.com/production/",
  "install_path": "\\\\?\\C:\\Program Files\\Autodesk\\webdeploy\\production\\6f81bda0bb0ebef0ea118cf2bd48cba17061ffb5\\Fusion360.exe",
  "manifest": {
    "build-version": "2702.1.47",
    "major-update-version": "2.0.1986",
    "release-version": "20260412194756",
    "properties": {
      "display-name": "Autodesk Fusion"
    },
    "streamer": {
      "feature-version": "20260227094542",
      "release-id": "2702"
    }
  },
  "stream": "production",
  "uuid": "73e72ada57b7480280f7a6f4a289729f"
}
```

Create `tests/fixtures/action1-installed-fusion.json`:

```json
{
  "items": [
    { "fields": { "Name": "Autodesk Fusion", "Version": "2701.1.27", "Endpoints": "2" } },
    { "fields": { "Name": "Autodesk Fusion", "Version": "2702.1.47", "Endpoints": "1" } },
    { "fields": { "Name": "Autodesk Fusion", "Version": "2702.1.58", "Endpoints": "1" } },
    { "fields": { "Name": "Autodesk Fusion 360", "Version": "2.0.17453", "Endpoints": "1" } }
  ]
}
```

Create `tests/fixtures/autodesk-head-current.json`:

```json
{
  "Url": "https://dl.appstreaming.autodesk.com/production/installers/Fusion%20Admin%20Install.exe",
  "LastModified": "Thu, 23 Apr 2026 03:21:46 GMT",
  "ETag": "\"945f8d5c5e70f2a1ffa5f7e666a72247:1776914468.464812\"",
  "ContentLength": "1486420912"
}
```

- [ ] **Step 3: Create tests that fail because the module does not exist**

Create `tests/FusionManagedUpdate.Tests.ps1`:

```powershell
$repoRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repoRoot 'src/FusionManagedUpdate.Common.psm1'
Import-Module $modulePath -Force

$fixtureRoot = Join-Path $PSScriptRoot 'fixtures'

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

$warning = New-HistoricalVersionWarning -BuildVersion '2702.1.58' -DetectedDate '2026-04-30'
Assert-True ($warning -like '*historical build*') 'Warning says historical builds are not pinned installers'
Assert-True ($warning -like '*currently available Fusion build*') 'Warning says Autodesk controls currently available build'
```

- [ ] **Step 4: Run tests and verify failure**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

Expected: FAIL because `src/FusionManagedUpdate.Common.psm1` does not exist.

- [ ] **Step 5: Commit test harness**

```powershell
git add tests
git commit -m "test: add Fusion updater test harness"
```

## Task 2: Shared Common Module

**Files:**
- Create: `src/FusionManagedUpdate.Common.psm1`
- Modify: `tests/FusionManagedUpdate.Tests.ps1`

- [ ] **Step 1: Implement the shared module**

Create `src/FusionManagedUpdate.Common.psm1`:

```powershell
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
```

- [ ] **Step 2: Run tests and verify pass**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

Expected: PASS for all helper tests.

- [ ] **Step 3: Commit common module**

```powershell
git add src/FusionManagedUpdate.Common.psm1 tests/FusionManagedUpdate.Tests.ps1
git commit -m "feat: add Fusion updater shared helpers"
```

## Task 3: Endpoint Updater Script

**Files:**
- Create: `src/Invoke-FusionManagedUpdate.ps1`
- Modify: `tests/FusionManagedUpdate.Tests.ps1`

- [ ] **Step 1: Add endpoint behavior tests**

Append these tests to `tests/FusionManagedUpdate.Tests.ps1`:

```powershell
$tempRoot = Join-Path $env:TEMP ('fmu-test-' + [guid]::NewGuid().ToString('N'))
$streamerDir = Join-Path $tempRoot 'Autodesk\webdeploy\meta\streamer\20260227094542'
New-Item -ItemType Directory -Path $streamerDir -Force | Out-Null
New-Item -ItemType File -Path (Join-Path $streamerDir 'streamer.exe') -Force | Out-Null

$foundStreamer = Get-LatestFusionStreamer -WebDeployRoot (Join-Path $tempRoot 'Autodesk\webdeploy')
Assert-True ($foundStreamer -like '*streamer.exe') 'Latest streamer path is detected'

Remove-Item -LiteralPath $tempRoot -Recurse -Force
```

Expected failure: `Get-LatestFusionStreamer` is not defined.

- [ ] **Step 2: Add endpoint helper functions to the module**

Append to `src/FusionManagedUpdate.Common.psm1` before `Export-ModuleMember`:

```powershell
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
```

Update the export line to include `Get-LatestFusionStreamer`.

- [ ] **Step 3: Create endpoint updater**

Create `src/Invoke-FusionManagedUpdate.ps1`:

```powershell
[CmdletBinding()]
param(
    [string]$WebDeployRoot = 'C:\Program Files\Autodesk\webdeploy',
    [ValidateSet('Fail', 'Wait', 'ForceClose')]
    [string]$RunningProcessPolicy = 'Wait',
    [int]$WaitSeconds = 3600
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'FusionManagedUpdate.Common.psm1'
Import-Module $modulePath -Force

function Write-Info([string]$Message) {
    Write-Host "[FusionManagedUpdater] $Message"
}

function Stop-OrWaitFusionProcesses {
    param(
        [ValidateSet('Fail', 'Wait', 'ForceClose')][string]$Policy,
        [int]$TimeoutSeconds
    )
    $names = @('Fusion360', 'FusionLauncher', 'Autodesk Fusion 360')
    $processes = Get-Process -ErrorAction SilentlyContinue | Where-Object { $names -contains $_.ProcessName }
    if (-not $processes) { return }

    Write-Info "Fusion is running. Policy: $Policy"
    if ($Policy -eq 'Fail') {
        throw 'Fusion is running and RunningProcessPolicy is Fail.'
    }
    if ($Policy -eq 'Wait') {
        try {
            Wait-Process -InputObject $processes -Timeout $TimeoutSeconds -ErrorAction Stop
            return
        } catch {
            throw "Fusion did not close within $TimeoutSeconds seconds."
        }
    }
    if ($Policy -eq 'ForceClose') {
        $processes | Stop-Process -Force
        Start-Sleep -Seconds 2
        return
    }
}

if (-not (Test-Path -LiteralPath $WebDeployRoot)) {
    throw "All-users Fusion webdeploy root was not found: $WebDeployRoot. Install the Fusion lab/admin package before running this updater."
}

$streamer = Get-LatestFusionStreamer -WebDeployRoot $WebDeployRoot
Write-Info "Using streamer: $streamer"
Write-Info 'Autodesk controls the actual streamed target. Historical Action1 versions are release records, not rollback installers.'

$beforePath = Join-Path $env:TEMP ('fusion-before-' + [guid]::NewGuid().ToString('N') + '.json')
$afterPath = Join-Path $env:TEMP ('fusion-after-' + [guid]::NewGuid().ToString('N') + '.json')

& $streamer --globalinstall --process query --infofile $beforePath --quiet
if ($LASTEXITCODE -ne 0) {
    throw "Fusion query failed before update with exit code $LASTEXITCODE."
}
$before = Read-FusionInfoFile -Path $beforePath
Write-Info "Before update: build=$($before.BuildVersion), release=$($before.ReleaseVersion), installPath=$($before.InstallPath)"

Stop-OrWaitFusionProcesses -Policy $RunningProcessPolicy -TimeoutSeconds $WaitSeconds

& $streamer --globalinstall --process update --quiet
if ($LASTEXITCODE -ne 0) {
    throw "Fusion streamer update failed with exit code $LASTEXITCODE."
}

& $streamer --globalinstall --process query --infofile $afterPath --quiet
if ($LASTEXITCODE -ne 0) {
    throw "Fusion query failed after update with exit code $LASTEXITCODE."
}
$after = Read-FusionInfoFile -Path $afterPath
Write-Info "After update: build=$($after.BuildVersion), release=$($after.ReleaseVersion), installPath=$($after.InstallPath)"

if (-not $after.BuildVersion) {
    throw 'Post-update verification did not return a Fusion build version.'
}

exit 0
```

- [ ] **Step 4: Run tests and verify pass**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

Expected: PASS.

- [ ] **Step 5: Commit endpoint updater**

```powershell
git add src tests
git commit -m "feat: add Fusion endpoint updater"
```

## Task 4: Single-File Action1 Payload Builder

**Files:**
- Create: `packaging/build-action1-payload.ps1`
- Create: `dist/.gitkeep`
- Modify: `tests/FusionManagedUpdate.Tests.ps1`

- [ ] **Step 1: Create payload builder**

Create `packaging/build-action1-payload.ps1`:

```powershell
[CmdletBinding()]
param(
    [string]$SourceScript = (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\Invoke-FusionManagedUpdate.ps1'),
    [string]$CommonModule = (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\FusionManagedUpdate.Common.psm1'),
    [string]$OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist\FusionManagedUpdater.cmd')
)

$ErrorActionPreference = 'Stop'
$outputDir = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$moduleText = Get-Content -LiteralPath $CommonModule -Raw
$scriptText = Get-Content -LiteralPath $SourceScript -Raw
$moduleEncoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($moduleText))
$scriptEncoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($scriptText))
$moduleLines = $moduleEncoded -split '(.{1,7000})' | Where-Object { $_ }
$scriptLines = $scriptEncoded -split '(.{1,7000})' | Where-Object { $_ }
$cmd = New-Object System.Collections.Generic.List[string]
$cmd.Add('@echo off')
$cmd.Add('setlocal EnableExtensions')
$cmd.Add('set "work=%TEMP%\FusionManagedUpdater-%RANDOM%%RANDOM%"')
$cmd.Add('mkdir "%work%" >nul 2>nul')
$cmd.Add('set "moduleb64=%work%\module.b64"')
$cmd.Add('set "scriptb64=%work%\script.b64"')
$cmd.Add('set "module=%work%\FusionManagedUpdate.Common.psm1"')
$cmd.Add('set "ps1=%work%\Invoke-FusionManagedUpdate.ps1"')
$cmd.Add('break > "%moduleb64%"')
foreach ($line in $moduleLines) {
    $cmd.Add(">> `"%moduleb64%`" echo $line")
}
$cmd.Add('break > "%scriptb64%"')
foreach ($line in $scriptLines) {
    $cmd.Add(">> `"%scriptb64%`" echo $line")
}
$cmd.Add('powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[IO.File]::WriteAllBytes($env:module, [Convert]::FromBase64String((Get-Content -LiteralPath $env:moduleb64 -Raw))); [IO.File]::WriteAllBytes($env:ps1, [Convert]::FromBase64String((Get-Content -LiteralPath $env:scriptb64 -Raw)))"')
$cmd.Add('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ps1%"')
$cmd.Add('set "code=%ERRORLEVEL%"')
$cmd.Add('rmdir /s /q "%work%" >nul 2>nul')
$cmd.Add('exit /b %code%')

Set-Content -LiteralPath $OutputPath -Value $cmd -Encoding ASCII
Write-Host "Wrote Action1 payload: $OutputPath"
```

- [ ] **Step 2: Create dist marker**

```powershell
New-Item -ItemType Directory -Path .\dist -Force
Set-Content -LiteralPath .\dist\.gitkeep -Value ''
```

- [ ] **Step 3: Run payload builder**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\packaging\build-action1-payload.ps1
```

Expected: `dist\FusionManagedUpdater.cmd` exists and is under 1 MB.

- [ ] **Step 4: Commit payload builder**

```powershell
git add packaging dist/.gitkeep
git commit -m "feat: add Action1 payload builder"
```

## Task 5: Admin Watcher Dry-Run

**Files:**
- Create: `src/Watch-FusionAction1Release.ps1`
- Modify: `tests/FusionManagedUpdate.Tests.ps1`

- [ ] **Step 1: Add watcher payload tests**

Append to `tests/FusionManagedUpdate.Tests.ps1`:

```powershell
$versionDescription = New-HistoricalVersionWarning -BuildVersion '2702.1.58' -DetectedDate '2026-04-30'
$versionBody = New-Action1FusionVersionBody -BuildVersion '2702.1.58' -DetectedDate '2026-04-30' -PayloadFileName 'FusionManagedUpdater.cmd'
Assert-Equal $versionBody.version '2702.1.58' 'Action1 version body uses Fusion build version'
Assert-Equal $versionBody.app_name_match '^Autodesk Fusion(?: 360)?$' 'Action1 version body matches current and legacy Fusion names'
Assert-True ($versionBody.description -eq $versionDescription) 'Action1 version body includes historical warning'
Assert-Equal $versionBody.silent_install_switches '' 'Action1 payload launcher needs no switches'
Assert-Equal $versionBody.success_exit_codes '0' 'Action1 success exit code is zero'
```

Expected failure: `New-Action1FusionVersionBody` is not defined.

- [ ] **Step 2: Add Action1 body builder to common module**

Append to `src/FusionManagedUpdate.Common.psm1` before the export line:

```powershell
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
```

Update the export line to include `New-Action1FusionVersionBody`.

- [ ] **Step 3: Create watcher script**

Create `src/Watch-FusionAction1Release.ps1`:

```powershell
[CmdletBinding()]
param(
    [string]$AutodeskInstallerUrl = 'https://dl.appstreaming.autodesk.com/production/installers/Fusion%20Admin%20Install.exe',
    [string]$StatePath = (Join-Path $PSScriptRoot '..\state\fusion-release-state.json'),
    [string]$PackageId = $env:ACTION1_FUSION_PACKAGE_ID,
    [string]$OrgId = $(if ($env:ACTION1_ORG_ID) { $env:ACTION1_ORG_ID } else { 'all' }),
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'FusionManagedUpdate.Common.psm1'
Import-Module $modulePath -Force

function Read-State {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    return [pscustomobject]@{}
}

function Write-State {
    param([string]$Path, $State)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-Action1Api {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST', 'PATCH')][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        [object]$Body
    )
    $baseUrl = if ($env:ACTION1_BASE_URL) { $env:ACTION1_BASE_URL.TrimEnd('/') } else { 'https://app.action1.com/api/3.0' }
    $token = $env:ACTION1_ACCESS_TOKEN
    if (-not $token) {
        throw 'ACTION1_ACCESS_TOKEN is required for live Action1 API calls.'
    }
    $headers = @{ Authorization = "Bearer $token" }
    $uri = "$baseUrl/$($Path.TrimStart('/'))"
    if ($Body) {
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Depth 20)
    }
    return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
}

$state = Read-State -Path $StatePath
$head = Get-AutodeskInstallerHead -Url $AutodeskInstallerUrl
$changed = ($state.ETag -ne $head.ETag) -or ($state.LastModified -ne $head.LastModified) -or ($state.ContentLength -ne $head.ContentLength)

if (-not $changed) {
    Write-Host 'No Autodesk installer release signal changed.'
    exit 0
}

$detectedDate = (Get-Date).ToString('yyyy-MM-dd')
$buildVersion = if ($env:FUSION_OBSERVED_BUILD_VERSION) { $env:FUSION_OBSERVED_BUILD_VERSION } else { 'unknown-' + (Get-Date).ToString('yyyyMMddHHmmss') }
$body = New-Action1FusionVersionBody -BuildVersion $buildVersion -DetectedDate $detectedDate -PayloadFileName 'FusionManagedUpdater.cmd'

if ($DryRun) {
    [pscustomobject]@{
        Changed = $changed
        AutodeskHead = $head
        Action1VersionBody = $body
    } | ConvertTo-Json -Depth 20
    exit 0
}

if (-not $PackageId) {
    throw 'ACTION1_FUSION_PACKAGE_ID or -PackageId is required for live version creation.'
}

Invoke-Action1Api -Method POST -Path "/software-repository/$OrgId/$PackageId/versions" -Body $body | Out-Null
Write-State -Path $StatePath -State $head
Write-Host "Created Action1 Fusion history version for $buildVersion."
```

- [ ] **Step 4: Run tests**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

Expected: PASS.

- [ ] **Step 5: Run watcher dry-run**

Run:

```powershell
$env:FUSION_OBSERVED_BUILD_VERSION='2702.1.58'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\Watch-FusionAction1Release.ps1 -DryRun
```

Expected: JSON output with `Changed`, `AutodeskHead`, and `Action1VersionBody`.

- [ ] **Step 6: Commit watcher dry-run**

```powershell
git add src tests
git commit -m "feat: add Fusion release watcher dry-run"
```

## Task 6: Action1 Validation And Live Integration

**Files:**
- Modify: `src/Watch-FusionAction1Release.ps1`
- Create: `action1/package-description.md`

- [ ] **Step 1: Create package description**

Create `action1/package-description.md`:

```markdown
# Autodesk Fusion Managed Updater

This Action1 package runs a small PowerShell wrapper that invokes Autodesk's live Fusion streamer update process.

Historical Action1 versions are retained for release history only. Fusion is delivered by Autodesk's live streamer endpoint. Deploying an older Action1 version updates endpoints to Autodesk's currently available Fusion build, not to the historical build recorded by that Action1 version.
```

- [ ] **Step 2: Validate match conflicts with Action1 MCP before live creation**

Run the Action1 match-conflict check for:

```text
^Autodesk Fusion(?: 360)?$
```

Expected: no conflicting custom package match that would prevent this package from matching Fusion inventory.

- [ ] **Step 3: Validate package creation payload with Action1 dry-run**

Use the Action1 create package tool in dry-run mode with this body:

```json
{
  "name": "Autodesk Fusion Managed Updater",
  "vendor": "Autodesk",
  "description": "Small Action1-managed updater for Autodesk Fusion. Historical versions are release records only; Autodesk's live streamer controls the actual installable build.",
  "platform": "Windows",
  "internal_notes": "Do not use this package for rollback. Deployments run Autodesk's currently available Fusion streamer update."
}
```

Expected: Action1 returns a dry-run preview without validation errors.

- [ ] **Step 4: Validate version creation payload with Action1 dry-run**

Use the Action1 create package version tool in dry-run mode with the body produced by:

```powershell
Import-Module .\src\FusionManagedUpdate.Common.psm1 -Force
New-Action1FusionVersionBody -BuildVersion '2702.1.58' -DetectedDate '2026-04-30' -PayloadFileName 'FusionManagedUpdater.cmd' | ConvertTo-Json -Depth 20
```

Expected: Action1 returns a dry-run preview without validation errors.

- [ ] **Step 5: Adjust watcher only for fields Action1 rejects**

If the dry-run rejects any field, remove only the rejected field from `New-Action1FusionVersionBody`, rerun `tests/run-tests.ps1`, rerun the Action1 dry-run, and keep the historical warning text in `description` or `internal_notes`.

- [ ] **Step 6: Commit Action1 validation docs and accepted body shape**

```powershell
git add src action1 tests
git commit -m "feat: validate Action1 Fusion package payloads"
```

## Task 7: README And Operator Workflow

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write README**

Create `README.md`:

```markdown
# Autodesk Fusion Action1 Managed Updater

This repository builds a small Action1 package payload that updates Autodesk Fusion through Autodesk's live streamer endpoint.

## Package Semantics

Action1 versions are release-history records. They do not pin old Fusion payloads. Autodesk's streamer controls the actual installable build. Deploying an older Action1 version will still update the endpoint to Autodesk's currently available Fusion build.

## Build Payload

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\packaging\build-action1-payload.ps1
```

Output:

```text
dist\FusionManagedUpdater.cmd
```

## Run Tests

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

## Endpoint Dry Run

Run this only on a lab machine with all-users Fusion installed:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\Invoke-FusionManagedUpdate.ps1 -RunningProcessPolicy Fail
```

## Watcher Dry Run

```powershell
$env:FUSION_OBSERVED_BUILD_VERSION='2702.1.58'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\Watch-FusionAction1Release.ps1 -DryRun
```

## Live Watcher Environment

Set these environment variables before live Action1 writes:

```powershell
$env:ACTION1_ACCESS_TOKEN='<Action1 bearer token>'
$env:ACTION1_ORG_ID='<Action1 organization id or all>'
$env:ACTION1_FUSION_PACKAGE_ID='<Action1 package id>'
```

## Recommended Deployment

1. Run tests.
2. Build `dist\FusionManagedUpdater.cmd`.
3. Run watcher dry-run.
4. Validate Action1 package/version dry-runs.
5. Deploy to one pilot endpoint.
6. Refresh Action1 installed software inventory.
7. Approve broader deployment.
```

- [ ] **Step 2: Run tests and payload build**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\packaging\build-action1-payload.ps1
```

Expected: tests pass and `dist\FusionManagedUpdater.cmd` is created.

- [ ] **Step 3: Commit README**

```powershell
git add README.md
git commit -m "docs: document Fusion Action1 updater workflow"
```

## Task 8: Final Verification

**Files:**
- No source files unless verification finds a defect.

- [ ] **Step 1: Run full local verification**

Run:

```powershell
git status --short
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\packaging\build-action1-payload.ps1
Get-Item .\dist\FusionManagedUpdater.cmd | Select-Object FullName,Length,LastWriteTime
```

Expected:

- `git status --short` shows no uncommitted source changes before generated payload creation.
- Tests print `All tests passed.`
- Payload builder prints `Wrote Action1 payload`.
- Payload file exists.

- [ ] **Step 2: Capture final package warning text**

Run:

```powershell
Import-Module .\src\FusionManagedUpdate.Common.psm1 -Force
New-HistoricalVersionWarning -BuildVersion '2702.1.58' -DetectedDate '2026-04-30'
```

Expected output includes:

```text
Deploying this or any older version will update the endpoint to Autodesk's currently available Fusion build, not necessarily this historical build.
```

- [ ] **Step 3: Commit final generated payload only if storing build artifacts is desired**

Default repository behavior should not commit `dist\FusionManagedUpdater.cmd`. If the user wants the built artifact versioned, run:

```powershell
git add dist/FusionManagedUpdater.cmd
git commit -m "build: add Fusion managed updater payload"
```

If the user does not want generated artifacts committed, leave only `dist/.gitkeep` tracked.

## Self-Review

- Spec coverage: endpoint updater, admin watcher, small Action1 payload, historical version warning, all-users-only scope, and manual approval default are covered.
- Placeholder scan: no unresolved implementation markers are intentionally left in this plan.
- Type consistency: the common module exports are used by tests, endpoint updater, watcher, and README commands with the same function names.
