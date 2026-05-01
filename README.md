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

Live watcher runs also require `FUSION_OBSERVED_BUILD_VERSION` to be set to a real dotted numeric Fusion build version, such as `2702.1.58`.

Do not run live watcher mode until the manual gates in `action1/validation-notes.md` are complete. The script enforces build version, package ID, and token checks; it does not enforce the Action1 match-conflict gate by itself.

## Recommended Deployment

1. Run tests.
2. Build `dist\FusionManagedUpdater.cmd`.
3. Run watcher dry-run.
4. Complete the live-write preconditions in `action1/validation-notes.md`, including a successful match-conflict result with no blocking or conflicting package matches.
5. Validate Action1 package/version dry-runs.
6. Record the final conflict-check result and dry-run previews in `action1/validation-notes.md`.
7. Deploy to one pilot endpoint.
8. Refresh Action1 installed software inventory.
9. Approve broader deployment.
