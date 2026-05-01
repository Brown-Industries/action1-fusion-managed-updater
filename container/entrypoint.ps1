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

$null = Invoke-FusionContainerStartupSync -OneShot $config.OneShot -SyncCommand {
    Invoke-SyncOnce -ScriptPath $SyncScriptPath
}

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
            Write-Error $_ -ErrorAction Continue
        }
    }
}

$envFile = '/etc/action1-fusion-container.env'
$envSpec = New-FusionContainerCronEnvironmentSpec
$envSpec.Lines | Set-Content -LiteralPath $envFile -Encoding ASCII
chmod $envSpec.Mode $envFile

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
