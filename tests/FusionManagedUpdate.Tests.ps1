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
