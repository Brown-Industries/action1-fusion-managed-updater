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
    $OutputPath = Join-Path $repoRoot 'dist\FusionManagedUpdater.ps1'
}

$outputDir = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$moduleText = Get-Content -LiteralPath $CommonModule -Raw
$scriptText = Get-Content -LiteralPath $SourceScript -Raw
$moduleEncoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($moduleText))
$scriptEncoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($scriptText))
$moduleLines = $moduleEncoded -split '(.{1,1000})' | Where-Object { $_ }
$scriptLines = $scriptEncoded -split '(.{1,1000})' | Where-Object { $_ }
$payload = New-Object System.Collections.Generic.List[string]
$payload.Add('$ErrorActionPreference = ''Stop''')
$payload.Add('$work = Join-Path $env:TEMP (''FusionManagedUpdater-'' + [guid]::NewGuid().ToString(''N''))')
$payload.Add('New-Item -ItemType Directory -Path $work -Force | Out-Null')
$payload.Add('$module = Join-Path $work ''FusionManagedUpdate.Common.psm1''')
$payload.Add('$ps1 = Join-Path $work ''Invoke-FusionManagedUpdate.ps1''')
$payload.Add('$exitCode = 1')
$payload.Add('$moduleb64 = @(')
foreach ($line in $moduleLines) {
    $payload.Add("    '$line'")
}
$payload.Add(') -join ''''')
$payload.Add('$scriptb64 = @(')
foreach ($line in $scriptLines) {
    $payload.Add("    '$line'")
}
$payload.Add(') -join ''''')
$payload.Add('try {')
$payload.Add('    [IO.File]::WriteAllBytes($module, [Convert]::FromBase64String($moduleb64))')
$payload.Add('    [IO.File]::WriteAllBytes($ps1, [Convert]::FromBase64String($scriptb64))')
$payload.Add('    & ''powershell.exe'' -NoProfile -ExecutionPolicy Bypass -File $ps1 @args')
$payload.Add('    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }')
$payload.Add('}')
$payload.Add('catch {')
$payload.Add('    Write-Error $_ -ErrorAction Continue')
$payload.Add('    $exitCode = 1')
$payload.Add('}')
$payload.Add('finally {')
$payload.Add('    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }')
$payload.Add('}')
$payload.Add('exit $exitCode')

Set-Content -LiteralPath $OutputPath -Value $payload -Encoding ASCII
$payloadSize = (Get-Item -LiteralPath $OutputPath).Length
if ($payloadSize -ge 1MB) {
    throw "Action1 payload is $payloadSize bytes, which must be under 1048576 bytes: $OutputPath"
}

Write-Host "Wrote Action1 payload: $OutputPath ($payloadSize bytes)"
