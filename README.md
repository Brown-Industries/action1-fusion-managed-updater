# Autodesk Fusion Action1 Managed Updater

This repository builds a small Action1 package payload that updates Autodesk Fusion through Autodesk's live streamer endpoint.

## Package Semantics

Action1 versions are release-history records. They do not pin old Fusion payloads. Autodesk's streamer controls the actual installable build. Deploying an older Action1 version will still update the endpoint to Autodesk's currently available Fusion build.

Historical versions are not rollback installers. Use them as audit records for observed Fusion builds and Action1 release history only.

## Build Payload

Command:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\packaging\build-action1-payload.ps1
```

Output:
```text
dist\FusionManagedUpdater.cmd
```

The generated payload is ignored by git by default. `dist/.gitkeep` is tracked only to keep the output directory present.

The payload forwards any arguments it receives to `Invoke-FusionManagedUpdate.ps1`. Useful Action1 install switches include:

```text
-RunningProcessPolicy Fail
-RunningProcessPolicy Wait -WaitSeconds 1800
```

Leave switches blank for the default behavior: wait up to 3600 seconds for user-facing Fusion processes to close.

## Run Tests

Command:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

## Endpoint Lab Update Test

This performs a real Autodesk streamer update on the machine. Run it only on a lab machine with all-users Fusion installed:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\Invoke-FusionManagedUpdate.ps1 -RunningProcessPolicy Fail
```

## Watcher Dry Run

Dry-run does not call Action1 inventory. Set `FUSION_OBSERVED_BUILD_VERSION` only when you want the preview body to show a specific build:

```powershell
$env:FUSION_OBSERVED_BUILD_VERSION='2702.1.58'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\Watch-FusionAction1Release.ps1 -DryRun
```

After testing, clear or reset `FUSION_OBSERVED_BUILD_VERSION` so a sample value is not reused accidentally.

## Live Watcher Environment

Set these environment variables before live Action1 writes:
```powershell
$env:ACTION1_ACCESS_TOKEN='<Action1 bearer token>'
$env:ACTION1_FUSION_PACKAGE_ID='<Action1 package id>'
$env:ACTION1_ORG_ID='<Action1 organization id or all>'
```

`ACTION1_ORG_ID` defaults to `all` if unset. Live watcher runs query Action1 installed software inventory for `Autodesk Fusion` and use the highest observed Fusion version as the Action1 package version to create.

`FUSION_OBSERVED_BUILD_VERSION` is optional in live mode. If set, it must match the highest Action1 inventory version. Use `-AllowManualObservedBuild` only when you verified the build outside Action1 and need to create the history version before inventory catches up.

Before posting a new version, the watcher also loads the Action1 package with `fields=versions` and exits without creating a duplicate if the target build version already exists.

Do not run live watcher mode until the manual gates in `action1/validation-notes.md` are complete. The script enforces Action1 inventory build resolution, manual-version mismatch checks, duplicate version checks, package ID, and token checks; it does not enforce the Action1 match-conflict gate by itself.

## Recommended Deployment

1. Run tests.
2. Build `dist\FusionManagedUpdater.cmd`.
3. Run watcher dry-run.
4. Complete the live-write preconditions in `action1/validation-notes.md`, including a successful match-conflict result with no blocking or conflicting package matches.
5. Validate Action1 package/version dry-runs using the connector, API, or UI flow documented in `action1/validation-notes.md`.
6. Record the final conflict-check result and dry-run previews in `action1/validation-notes.md`.
7. Refresh Action1 installed software inventory and confirm it reports the Fusion build you want to record.
8. Run the live watcher without `-DryRun` to create the Action1 version:
   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\Watch-FusionAction1Release.ps1
   ```
9. Deploy to one pilot endpoint.
10. Refresh Action1 installed software inventory.
11. Approve broader deployment.
