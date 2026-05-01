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
    else {
        try {
            $sourceUri = [Uri]$Source
            if ($sourceUri.IsAbsoluteUri) {
                $sourceExtension = [IO.Path]::GetExtension([Uri]::UnescapeDataString($sourceUri.AbsolutePath))
                if (-not [string]::IsNullOrWhiteSpace($sourceExtension)) {
                    $extension = $sourceExtension
                }
            }
        }
        catch {
        }
    }
    return Join-Path $WorkRoot ('FusionAdminInstall-' + [guid]::NewGuid().ToString('N') + $extension)
}

function Get-FusionCurlDownloaderPath {
    if (-not [string]::IsNullOrWhiteSpace($env:FMU_CURL_PATH)) {
        return $env:FMU_CURL_PATH
    }

    $curl = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($curl) {
        return $curl.Source
    }

    return ''
}

function Save-FusionAdminInstallerFromRemote {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Target
    )

    $curl = Get-FusionCurlDownloaderPath
    if (-not [string]::IsNullOrWhiteSpace($curl)) {
        Write-Step -Name 'bootstrap_download_method' -Message "method=curl command=$curl"
        $curlExitCode = Invoke-FusionChildProcess -FilePath $curl -ArgumentList @(
            '--fail',
            '--location',
            '--retry', '3',
            '--retry-delay', '5',
            '--connect-timeout', '60',
            '--max-time', '3600',
            '--output', $Target,
            $Source
        )
        if ($curlExitCode -ne 0) {
            throw "Fusion admin installer curl download failed with exit code $curlExitCode."
        }
        return
    }

    if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
        Write-Step -Name 'bootstrap_download_method' -Message 'method=bits'
        Start-BitsTransfer -Source $Source -Destination $Target -ErrorAction Stop
        return
    }

    Write-Step -Name 'bootstrap_download_method' -Message 'method=invoke_webrequest'
    Invoke-WebRequest -Uri $Source -OutFile $Target -UseBasicParsing -MaximumRedirection 5 -TimeoutSec 3600
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
        Write-Step -Name 'bootstrap_download_method' -Message 'method=copy'
        Copy-Item -LiteralPath $Source -Destination $target -Force
    }
    else {
        try {
            Save-FusionAdminInstallerFromRemote -Source $Source -Target $target
        }
        catch {
            Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
            throw
        }
    }

    if (-not (Test-Path -LiteralPath $target)) {
        throw "Fusion admin installer download did not create target file: $target"
    }

    $downloadedInstaller = Get-Item -LiteralPath $target
    if ($downloadedInstaller.Length -le 0) {
        Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        throw "Fusion admin installer download produced an empty file: $target"
    }
    Write-Step -Name 'bootstrap_download_success' -Message "path=$target bytes=$($downloadedInstaller.Length)"
    return $target
}

function ConvertTo-ProcessArgumentString {
    param([string[]]$ArgumentList)

    $quoted = foreach ($argument in $ArgumentList) {
        $value = [string]$argument
        if ([string]::IsNullOrEmpty($value)) {
            '""'
        }
        elseif ($value -notmatch '[\s"]') {
            $value
        }
        else {
            '"' + $value.Replace('"', '\"') + '"'
        }
    }
    return ($quoted -join ' ')
}

function Get-CurrentPowerShellExecutable {
    try {
        $currentProcess = Get-Process -Id $PID -ErrorAction Stop
        if ($currentProcess.Path) {
            return $currentProcess.Path
        }
    }
    catch {
    }

    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) {
        return $pwsh.Source
    }

    return 'powershell.exe'
}

function Invoke-FusionChildProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )

    $processPath = $FilePath
    $processArguments = @($ArgumentList)
    if ([IO.Path]::GetExtension($FilePath) -ieq '.ps1') {
        $processPath = Get-CurrentPowerShellExecutable
        $processArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $FilePath) + $processArguments
    }

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $processPath
    $startInfo.Arguments = ConvertTo-ProcessArgumentString -ArgumentList $processArguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true

    $workingDirectory = Split-Path -Parent $FilePath
    if ($workingDirectory -and (Test-Path -LiteralPath $workingDirectory)) {
        $startInfo.WorkingDirectory = $workingDirectory
    }

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $process.WaitForExit()
        return $process.ExitCode
    }
    catch {
        throw "Failed to run process '$FilePath'. $($_.Exception.Message)"
    }
    finally {
        $process.Dispose()
    }
}

function Remove-FusionAdminInstallerFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Attempts = 30,
        [int]$DelaySeconds = 2
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $true
    }

    $lastError = ''
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            Write-LogLine "FMU_STEP bootstrap_installer_deleted path=$Path"
            return $true
        }
        catch {
            $lastError = $_.Exception.Message
            if ($attempt -lt $Attempts) {
                Start-Sleep -Seconds $DelaySeconds
            }
        }
    }

    Write-LogLine "FMU_STEP bootstrap_installer_delete_failed path=$Path error=$lastError"
    return $false
}

function Remove-StaleFusionAdminInstallers {
    param([Parameter(Mandatory = $true)][string]$WorkRoot)

    if (-not (Test-Path -LiteralPath $WorkRoot)) {
        return
    }

    Get-ChildItem -LiteralPath $WorkRoot -Filter 'FusionAdminInstall-*' -File -ErrorAction SilentlyContinue |
        ForEach-Object { [void](Remove-FusionAdminInstallerFile -Path $_.FullName -Attempts 3 -DelaySeconds 1) }
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
        $installerExitCode = Invoke-FusionChildProcess -FilePath $installerPath -ArgumentList @('--globalinstall', '--quiet')
        if ($installerExitCode -ne 0) {
            throw "Fusion admin bootstrap installer failed with exit code $installerExitCode."
        }
        Write-Step -Name 'bootstrap_install_success'
    }
    finally {
        if ($installerPath) {
            [void](Remove-FusionAdminInstallerFile -Path $installerPath)
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
    $queryExitCode = Invoke-FusionChildProcess -FilePath $Streamer -ArgumentList @('--globalinstall', '--process', 'query', '--infofile', $InfoPath, '--quiet')
    if ($queryExitCode -ne 0) {
        throw "Fusion query failed during $Phase with exit code $queryExitCode."
    }
    $info = Read-FusionInfoFile -Path $InfoPath
    if ([string]::IsNullOrWhiteSpace($info.InstallPath)) {
        throw "Fusion query during $Phase did not return an install path."
    }

    $normalizedInstallPath = [string]$info.InstallPath
    if ($normalizedInstallPath.StartsWith('\\?\')) {
        $normalizedInstallPath = $normalizedInstallPath.Substring(4)
    }
    if (-not (Test-Path -LiteralPath $normalizedInstallPath)) {
        throw "Fusion query during $Phase returned install path that does not exist: $($info.InstallPath)"
    }

    Write-Step -Name "${Phase}_query_success" -Message "build=$($info.BuildVersion) release=$($info.ReleaseVersion)"
    return $info
}

$beforePath = Join-Path $env:TEMP ('fusion-before-' + [guid]::NewGuid().ToString('N') + '.json')
$afterPath = Join-Path $env:TEMP ('fusion-after-' + [guid]::NewGuid().ToString('N') + '.json')

try {
    $installerRoot = if (-not [string]::IsNullOrWhiteSpace($InstallerWorkRoot)) { $InstallerWorkRoot } else { $env:TEMP }
    Remove-StaleFusionAdminInstallers -WorkRoot $installerRoot
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
    $updateExitCode = Invoke-FusionChildProcess -FilePath $streamer -ArgumentList @('--globalinstall', '--process', 'update', '--quiet')
    if ($updateExitCode -ne 0) {
        throw "Fusion streamer update failed with exit code $updateExitCode."
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
