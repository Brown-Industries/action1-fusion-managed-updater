[CmdletBinding()]
param(
    [string]$WebDeployRoot = 'C:\Program Files\Autodesk\webdeploy',
    [ValidateSet('Fail', 'Wait', 'ForceClose')]
    [string]$RunningProcessPolicy = 'Wait',
    [int]$WaitSeconds = 3600,
    [string]$StreamerPathOverride = ''
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
    $processes = Get-FusionBlockingProcesses
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

$beforePath = Join-Path $env:TEMP ('fusion-before-' + [guid]::NewGuid().ToString('N') + '.json')
$afterPath = Join-Path $env:TEMP ('fusion-after-' + [guid]::NewGuid().ToString('N') + '.json')

try {
    if (-not (Test-Path -LiteralPath $WebDeployRoot)) {
        throw "All-users Fusion webdeploy root was not found: $WebDeployRoot. Install the Fusion lab/admin package before running this updater."
    }

    $streamer = if ($StreamerPathOverride) { $StreamerPathOverride } else { Get-LatestFusionStreamer -WebDeployRoot $WebDeployRoot }
    Write-Info "Using streamer: $streamer"
    Write-Info 'Autodesk controls the actual streamed target. Historical Action1 versions are release records, not rollback installers.'

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
}
finally {
    foreach ($path in @($beforePath, $afterPath)) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            Remove-Item -LiteralPath $path -Force
        }
    }
}

exit 0
