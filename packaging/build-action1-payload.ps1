[CmdletBinding()]
param(
    [string]$SourceScript,
    [string]$CommonModule,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $SourceScript) {
    $SourceScript = Join-Path $repoRoot 'src\Invoke-FusionManagedUpdate.ps1'
}

if (-not $CommonModule) {
    $CommonModule = Join-Path $repoRoot 'src\FusionManagedUpdate.Common.psm1'
}

if (-not $OutputPath) {
    $OutputPath = Join-Path $repoRoot 'dist\FusionManagedUpdater.cmd'
}

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
$cmd.Add('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ps1%" %*')
$cmd.Add('set "code=%ERRORLEVEL%"')
$cmd.Add('rmdir /s /q "%work%" >nul 2>nul')
$cmd.Add('exit /b %code%')

Set-Content -LiteralPath $OutputPath -Value $cmd -Encoding ASCII
$payloadSize = (Get-Item -LiteralPath $OutputPath).Length
if ($payloadSize -ge 1MB) {
    throw "Action1 payload is $payloadSize bytes, which must be under 1048576 bytes: $OutputPath"
}

Write-Host "Wrote Action1 payload: $OutputPath ($payloadSize bytes)"
