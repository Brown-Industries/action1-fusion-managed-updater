# Autodesk Fusion Action1 Managed Updater Design

Date: 2026-04-30

## Purpose

Automate Autodesk Fusion lab updates from Action1 without uploading the full Fusion admin installer for every release. Action1 will be the control, approval, inventory, and history layer. Autodesk's live streamer endpoint will remain the payload source.

## Evidence And Constraints

- The local PDF `C:\Users\Paul\Downloads\Advanced_Fusion360_Lab_Installation_Instructions_en-GB.pdf` describes Fusion lab/admin installs as streamer-based.
- Autodesk's lab install help page, last shown as updated on 2026-01-09, says the lab install package can be run from command line, script, or software distribution tools.
- The PDF documents `streamer.exe --globalinstall --process update --quiet` for updates and `streamer.exe --globalinstall --process query --infofile <path>` for installed version metadata.
- The live Windows admin installer URL `https://dl.appstreaming.autodesk.com/production/installers/Fusion%20Admin%20Install.exe` currently responds successfully and is about 1.49 GB.
- Action1 inventory already sees Fusion as installed software named `Autodesk Fusion` or older `Autodesk Fusion 360`, with versions such as `2702.1.47` and `2702.1.58`.
- Autodesk controls what the streamer currently installs. Historical Action1 versions cannot reliably pin or reinstall old Fusion builds unless full payloads are archived separately.

## Goals

- Keep Action1 package payloads small.
- Let Action1 deploy or schedule Fusion updates.
- Preserve a release history in Action1 versions.
- Make it explicit that historical versions are audit records, not rollback artifacts.
- Log the actual Fusion version installed after each endpoint update.
- Avoid unnecessary endpoint load and network traffic.

## Non-Goals

- Do not implement true rollback to old Fusion builds.
- Do not upload the full 1.49 GB admin installer for every release.
- Do not bypass Autodesk licensing, entitlement, or education access requirements.
- Do not force updates while Fusion is actively in use without a controlled wait/close policy.

## Architecture

The system has two parts:

1. Endpoint updater script
   - A small PowerShell script deployed by Action1.
   - Finds the all-users Fusion streamer under `C:\Program Files\Autodesk\webdeploy\meta\streamer`.
   - Queries the current installed Fusion version.
   - Runs Autodesk's streamer update command.
   - Queries the installed version again.
   - Returns success only when update execution and post-update verification pass.

2. Admin-side watcher script
   - A PowerShell or Python script run from an admin workstation, scheduled task, or CI runner.
   - Checks Autodesk release signals such as installer `ETag`, `Last-Modified`, `Content-Length`, and optionally observed Action1 inventory versions.
   - Creates a new Action1 Software Repository version when a new Fusion build is detected.
   - Writes package/version notes that state only Autodesk's currently served build is installable.

## Action1 Package Model

Package name: `Autodesk Fusion Managed Updater`

Package purpose: current-version enforcement for Autodesk Fusion through the Autodesk streamer.

Version semantics:

- Each Action1 version records a Fusion build observed at a point in time.
- The newest version is the normal deployable version.
- Older versions remain as release history.
- Older versions must be described as historical records, not installable rollback packages.

Required description language for every version:

```text
This version records Autodesk Fusion build <build> as detected on <date>. Fusion is delivered by Autodesk's live streamer endpoint. Deploying this or any older version will update the endpoint to Autodesk's currently available Fusion build, not necessarily this historical build. Only the latest Autodesk-served Fusion build is installable through this package.
```

Detection match:

- Primary `app_name_match`: `^Autodesk Fusion$`
- Optional legacy coverage: `^Autodesk Fusion(?: 360)?$`

The final regex must be checked with Action1's match-conflict API before package creation or version updates.

## Endpoint Updater Behavior

The endpoint updater should:

1. Detect whether Fusion is installed as all-users under `C:\Program Files\Autodesk\webdeploy`.
2. Find the newest `streamer.exe` directory by folder name under `meta\streamer`.
3. Query installed metadata into a temporary JSON file.
4. Print the current `build-version`, `major-update-version`, `release-version`, streamer feature version, and install path when available.
5. Warn that Autodesk controls the actual update target.
6. Check for running `Fusion360.exe`, `FusionLauncher.exe`, and related Fusion processes.
7. Wait for close or close processes according to the configured Action1 pre-check policy.
8. Run:

```powershell
streamer.exe --globalinstall --process update --quiet
```

9. Query Fusion metadata again.
10. Print the resulting installed version.
11. Return a nonzero exit code if the streamer is missing, query fails, update fails, or post-update verification cannot confirm the installed version.

If only a per-user Fusion install is found, the script should not silently modify it. It should exit with a clear message unless a future design explicitly allows per-user remediation.

## Admin Watcher Behavior

The watcher should:

1. Read saved state from a small local JSON file.
2. Perform a HEAD request against Autodesk's current admin installer URL.
3. Compare `ETag`, `Last-Modified`, and `Content-Length` with saved state.
4. Query Action1 installed software inventory for `Autodesk Fusion`.
5. Determine the highest observed Fusion version in Action1 inventory.
6. If a new build or release signal appears, create a new Action1 package version using the same small updater payload.
7. Set the new version description and internal notes with the historical-version warning.
8. Leave approval behavior configurable:
   - Default: create as not auto-approved, so an admin can approve deployment.
   - Optional: auto-approve after a successful pilot endpoint run.
9. Save the new watcher state only after Action1 has been updated successfully.

## Error Handling

- Missing streamer: fail with instructions to install the Fusion lab/admin package first.
- Running Fusion process: wait, notify, then fail or close depending on configuration.
- Autodesk endpoint unavailable: fail without changing Action1 state.
- Action1 API failure: fail without updating local watcher state.
- Version mismatch after update: print current and target/context values, then fail.
- Historical version deployment: print a warning but still run the current Autodesk streamer update.

## Testing Strategy

- Unit-test version parsing and version comparison.
- Unit-test Autodesk HEAD response parsing using saved sample headers.
- Unit-test local `fusioninfo.json` parsing using the observed local sample shape.
- Dry-run Action1 package creation and version creation before first live write.
- Pilot on one endpoint before broad deployment.
- Confirm Action1 inventory refresh shows the resulting installed Fusion version.

## Open Implementation Choices

- Use PowerShell for both scripts if the deployment host is Windows-only.
- Use Python for the watcher if richer API/state handling is preferred.
- The endpoint updater should be PowerShell because Action1 runs it naturally on Windows endpoints.
- The first implementation should target Windows/all-users Fusion only.

## Recommended First Build

Build the Windows-only version:

- PowerShell endpoint updater.
- PowerShell admin watcher.
- One Action1 custom package with small script payload.
- Historical Action1 versions retained with explicit warning text.
- Manual approval by default.

