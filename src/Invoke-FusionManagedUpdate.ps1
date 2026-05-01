[CmdletBinding()]
param(
    [string]$WebDeployRoot = 'C:\Program Files\Autodesk\webdeploy',
    [ValidateSet('Fail', 'Wait', 'ForceClose')]
    [string]$RunningProcessPolicy = 'Wait',
    [int]$WaitSeconds = 3600,
    [string]$StreamerPathOverride = '',
    [string]$AdminInstallerUrl = 'https://dl.appstreaming.autodesk.com/production/installers/Fusion%20Admin%20Install.exe',
    [string]$InstallerWorkRoot = '',
    [string]$LogPath = ''
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'FusionManagedUpdate.Common.psm1'
Import-Module $modulePath -Force

function Resolve-ManagedUpdaterLogPath {
    param([string]$RequestedPath)

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        return $RequestedPath
    }

    $root = if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) { $env:ProgramData } else { $env:TEMP }
    return Join-Path $root 'BrownIndustries\Action1FusionManagedUpdater\FusionManagedUpdater.log'
}

$script:LogPath = Resolve-ManagedUpdaterLogPath -RequestedPath $LogPath
$script:CurrentStep = 'start'

function Write-LogLine([string]$Line) {
    Write-Host $Line

    try {
        $logDir = Split-Path -Parent $script:LogPath
        if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $timestamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
        Add-Content -LiteralPath $script:LogPath -Encoding UTF8 -Value "$timestamp $Line"
    }
    catch {
        Write-Host "[FusionManagedUpdater] Failed to write log file '$script:LogPath': $($_.Exception.Message)"
    }
}

function Write-Info([string]$Message) {
    Write-LogLine "[FusionManagedUpdater] $Message"
}

function Write-Step {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Message = ''
    )

    $script:CurrentStep = $Name
    $line = if ([string]::IsNullOrWhiteSpace($Message)) { "FMU_STEP $Name" } else { "FMU_STEP $Name $Message" }
    Write-LogLine $line
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

function New-FusionAdminInstallerTargetPath {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$WorkRoot
    )

    $extension = '.exe'
    if (Test-Path -LiteralPath $Source) {
        $sourceExtension = [IO.Path]::GetExtension($Source)
        if (-not [string]::IsNullOrWhiteSpace($sourceExtension)) {
            $extension = $sourceExtension
        }
    }
    return Join-Path $WorkRoot ('FusionAdminInstall-' + [guid]::NewGuid().ToString('N') + $extension)
}

function Save-FusionAdminInstaller {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$WorkRoot
    )

    if (-not (Test-Path -LiteralPath $WorkRoot)) {
        New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
    }

    $target = New-FusionAdminInstallerTargetPath -Source $Source -WorkRoot $WorkRoot
    Write-Step -Name 'bootstrap_download_start' -Message "source=$Source target=$target"
    if (Test-Path -LiteralPath $Source) {
        Copy-Item -LiteralPath $Source -Destination $target -Force
    }
    else {
        Invoke-WebRequest -Uri $Source -OutFile $target -UseBasicParsing -MaximumRedirection 5 -TimeoutSec 3600
    }
    Write-Step -Name 'bootstrap_download_success' -Message "path=$target"
    return $target
}

function Invoke-FusionAdminBootstrapInstall {
    param(
        [Parameter(Mandatory = $true)][string]$InstallerSource,
        [Parameter(Mandatory = $true)][string]$WorkRoot
    )

    $installerPath = ''
    try {
        $installerPath = Save-FusionAdminInstaller -Source $InstallerSource -WorkRoot $WorkRoot
        Write-Step -Name 'bootstrap_install_start' -Message "installer=$installerPath"
        & $installerPath --globalinstall --quiet
        $installerExitCode = $LASTEXITCODE
        if ($null -ne $installerExitCode -and $installerExitCode -ne 0) {
            throw "Fusion admin bootstrap installer failed with exit code $installerExitCode."
        }
        Write-Step -Name 'bootstrap_install_success'
    }
    finally {
        if ($installerPath -and (Test-Path -LiteralPath $installerPath)) {
            Remove-Item -LiteralPath $installerPath -Force
            Write-LogLine "FMU_STEP bootstrap_installer_deleted path=$installerPath"
        }
    }
}

function Invoke-FusionQuery {
    param(
        [Parameter(Mandatory = $true)][string]$Streamer,
        [Parameter(Mandatory = $true)][string]$InfoPath,
        [Parameter(Mandatory = $true)][string]$Phase
    )

    Write-Step -Name "${Phase}_query_start"
    & $Streamer --globalinstall --process query --infofile $InfoPath --quiet
    if ($LASTEXITCODE -ne 0) {
        throw "Fusion query failed during $Phase with exit code $LASTEXITCODE."
    }
    $info = Read-FusionInfoFile -Path $InfoPath
    Write-Step -Name "${Phase}_query_success" -Message "build=$($info.BuildVersion) release=$($info.ReleaseVersion)"
    return $info
}

$beforePath = Join-Path $env:TEMP ('fusion-before-' + [guid]::NewGuid().ToString('N') + '.json')
$afterPath = Join-Path $env:TEMP ('fusion-after-' + [guid]::NewGuid().ToString('N') + '.json')

try {
    $installerRoot = if (-not [string]::IsNullOrWhiteSpace($InstallerWorkRoot)) { $InstallerWorkRoot } else { $env:TEMP }
    Write-Step -Name 'start' -Message "webDeployRoot=$WebDeployRoot logPath=$script:LogPath"

    $streamer = ''
    $bootstrapReason = ''
    if (-not (Test-Path -LiteralPath $WebDeployRoot)) {
        $bootstrapReason = "missingWebDeployRoot=$WebDeployRoot"
    }
    else {
        $streamerRoot = Join-Path $WebDeployRoot 'meta\streamer'
        if (-not (Test-Path -LiteralPath $streamerRoot)) {
            $bootstrapReason = "missingStreamerRoot=$streamerRoot"
        }
        elseif ($StreamerPathOverride) {
            $streamer = $StreamerPathOverride
        }
        else {
            try {
                $streamer = Get-LatestFusionStreamer -WebDeployRoot $WebDeployRoot
            }
            catch {
                $bootstrapReason = "streamerLookupFailed=$($_.Exception.Message)"
            }
        }
    }

    if ($bootstrapReason) {
        Write-Step -Name 'bootstrap_required' -Message $bootstrapReason
        Invoke-FusionAdminBootstrapInstall -InstallerSource $AdminInstallerUrl -WorkRoot $installerRoot
        if (-not (Test-Path -LiteralPath $WebDeployRoot)) {
            throw "Fusion admin bootstrap completed, but all-users Fusion webdeploy root was still not found: $WebDeployRoot."
        }

        $streamer = if ($StreamerPathOverride) { $StreamerPathOverride } else { Get-LatestFusionStreamer -WebDeployRoot $WebDeployRoot }
        Write-Info "Using streamer after bootstrap: $streamer"
        $after = Invoke-FusionQuery -Streamer $streamer -InfoPath $afterPath -Phase 'bootstrap'
        Write-Info "After bootstrap: build=$($after.BuildVersion), release=$($after.ReleaseVersion), installPath=$($after.InstallPath)"

        if (-not $after.BuildVersion) {
            throw 'Post-bootstrap verification did not return a Fusion build version.'
        }
        Write-Step -Name 'verification_success' -Message "build=$($after.BuildVersion)"
        exit 0
    }

    Write-Info "Using streamer: $streamer"
    Write-Info 'Autodesk controls the actual streamed target. Historical Action1 versions are release records, not rollback installers.'

    $before = Invoke-FusionQuery -Streamer $streamer -InfoPath $beforePath -Phase 'before_update'
    Write-Info "Before update: build=$($before.BuildVersion), release=$($before.ReleaseVersion), installPath=$($before.InstallPath)"

    Stop-OrWaitFusionProcesses -Policy $RunningProcessPolicy -TimeoutSeconds $WaitSeconds

    Write-Step -Name 'update_start'
    & $streamer --globalinstall --process update --quiet
    if ($LASTEXITCODE -ne 0) {
        throw "Fusion streamer update failed with exit code $LASTEXITCODE."
    }
    Write-Step -Name 'update_success'

    $after = Invoke-FusionQuery -Streamer $streamer -InfoPath $afterPath -Phase 'after_update'
    Write-Info "After update: build=$($after.BuildVersion), release=$($after.ReleaseVersion), installPath=$($after.InstallPath)"

    if (-not $after.BuildVersion) {
        throw 'Post-update verification did not return a Fusion build version.'
    }
    Write-Step -Name 'verification_success' -Message "build=$($after.BuildVersion)"
}
catch {
    $failedStep = $script:CurrentStep
    Write-LogLine "FMU_STEP failure failedStep=$failedStep error=$($_.Exception.Message)"
    throw "Fusion managed updater failed during '$failedStep'. $($_.Exception.Message)"
}
finally {
    foreach ($path in @($beforePath, $afterPath)) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            Remove-Item -LiteralPath $path -Force
        }
    }
}

exit 0
