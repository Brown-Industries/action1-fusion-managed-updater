# Autodesk Fusion Action1 Managed Updater

This repository builds a small Action1 package payload that installs or updates Autodesk Fusion through Autodesk's live admin installer and streamer endpoints.

## Package Semantics

Action1 versions are release-history records. They do not pin old Fusion payloads. Autodesk controls the actual installable build. Deploying an older Action1 version will still install or update the endpoint to Autodesk's currently available Fusion build.

Historical versions are not rollback installers. Use them as audit records for observed Fusion builds and Action1 release history only.

## Build Payload

Command:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\packaging\build-action1-payload.ps1
```

Output:
```text
dist\FusionManagedUpdater.ps1
```

The generated payload is ignored by git by default. `dist/.gitkeep` is tracked only to keep the output directory present.

The payload forwards any arguments it receives to `Invoke-FusionManagedUpdate.ps1`. Useful Action1 install switches include:

```text
-RunningProcessPolicy Fail
-RunningProcessPolicy Wait -WaitSeconds 1800
```

Leave switches blank for the default behavior: wait up to 3600 seconds for user-facing Fusion processes to close.

If the all-users Fusion webdeploy root is missing, the payload downloads Autodesk's current admin installer from:

```text
https://dl.appstreaming.autodesk.com/production/installers/Fusion%20Admin%20Install.exe
```

The downloaded installer is saved under the endpoint temp directory, run with `--quiet`, and deleted in a `finally` block whether install succeeds or fails. Remote downloads prefer `curl.exe` with redirect/retry/fail-fast options, then fall back to BITS and finally `Invoke-WebRequest` if needed. Set `FMU_CURL_PATH` only if an endpoint needs a specific curl executable. After bootstrap, the payload verifies the installed Fusion build and reported executable path with the Autodesk streamer. If all-users Fusion already exists, the payload skips bootstrap and runs the existing streamer update flow.

The endpoint writes progress to stdout for Action1 history and to a durable log:

```text
C:\ProgramData\BrownIndustries\Action1FusionManagedUpdater\FusionManagedUpdater.log
```

Progress lines use the `FMU_STEP` prefix, including `bootstrap_download_start`, `bootstrap_download_method`, `bootstrap_install_start`, `update_start`, `verification_success`, and `failure`.

## Run Tests

Command:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

## Container Usage

The intended public image is:

```text
brownindustries/action1-fusion-managed-updater:latest
```

The container is stateless. It queries Action1 each run, finds or creates the package named by `PACKAGE_NAME`, detects the highest Autodesk Fusion build reported in Action1 installed software inventory, then creates or completes the corresponding Action1 package version with the generated Windows updater payload. Payload filenames include a short content hash, so publishing a new updater image can refresh the existing Action1 version even when Autodesk's Fusion build number has not changed.

One-shot mode is the default:

```bash
docker run --rm \
  -e ACTION1_CLIENT_ID="..." \
  -e ACTION1_CLIENT_SECRET="..." \
  -e ACTION1_ORG_ID="all" \
  -e PACKAGE_NAME="Autodesk Fusion Managed Updater" \
  brownindustries/action1-fusion-managed-updater:latest
```

Long-running mode starts once immediately, then checks on an interval or cron schedule:

```bash
docker run -d --name action1-fusion-updater \
  -e ACTION1_CLIENT_ID="..." \
  -e ACTION1_CLIENT_SECRET="..." \
  -e ONE_SHOT="false" \
  -e CHECK_FREQUENCY_MINUTES="1440" \
  brownindustries/action1-fusion-managed-updater:latest
```

`CHECK_FREQUENCY_CRON` can be used instead of `CHECK_FREQUENCY_MINUTES` for standard five-field cron expressions.

Supported environment variables:

| Name | Required | Default | Purpose |
| --- | --- | --- | --- |
| `ACTION1_CLIENT_ID` | yes | none | Action1 API client ID. |
| `ACTION1_CLIENT_SECRET` | yes | none | Action1 API client secret. |
| `ACTION1_BASE_URL` | no | `https://app.action1.com/api/3.0` | Action1 API base URL. |
| `ACTION1_ORG_ID` | no | `all` | Action1 organization scope. |
| `PACKAGE_NAME` | no | `Autodesk Fusion Managed Updater` | Custom Action1 package name to find or create. |
| `ONE_SHOT` | no | `true` | `true` exits after one sync; `false` keeps scheduling sync runs. |
| `CHECK_FREQUENCY_MINUTES` | no | `1440` | Interval used when `ONE_SHOT=false` and no cron is set. |
| `CHECK_FREQUENCY_CRON` | no | none | Cron schedule used when `ONE_SHOT=false`. |

The example Compose file keeps both remote-image and local-build paths available:

```bash
docker compose -f docker-compose.example.yml up --build
```

## Public Image Publishing

`.github/workflows/docker-publish.yml` builds and publishes the container image to Docker Hub as `brownindustries/action1-fusion-managed-updater`.

Publishing events:

- Pull requests build the image but do not log in to Docker Hub and do not push.
- Pushes to the repository default branch publish `latest`, branch, and `sha-*` tags.
- `v*` tag pushes publish the matching version tag and `sha-*` tag.
- Manual workflow runs publish only when run from the default branch or a `v*` tag; other refs build only.
- If Docker Hub secrets are missing, eligible publish runs build the image and emit a warning instead of pushing.

Required GitHub repository secrets:

```text
DOCKER_HUB_REG_USERNAME
DOCKER_HUB_REG_PASSWORD
```

The GitHub repository should be public under the `Brown-Industries` organization, and the Docker Hub namespace/repository should be `brownindustries/action1-fusion-managed-updater`.

## Endpoint Lab Install/Update Test

This performs a real Autodesk bootstrap install when all-users Fusion is missing, or a streamer update when all-users Fusion is already installed. Run it only on a lab machine:
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

`ACTION1_ORG_ID` defaults to `all` if unset. In live mode, the watcher queries Action1 installed software inventory for `Autodesk Fusion` and uses the highest observed Fusion version as the Action1 package version to create.

`FUSION_OBSERVED_BUILD_VERSION` is optional in live mode. If set, it must match the highest Action1 inventory version. Use `-AllowManualObservedBuild` only when you verified the build outside Action1 and need to create the history version before inventory catches up.

Action1 accepts the historical warning on the package, but the live version-creation API rejects per-version `description` and `internal_notes`. Before posting a new version, the watcher loads the Action1 package with `fields=versions`. If the resolved inventory build is already recorded, the watcher fails without updating state so a stale Action1 inventory snapshot cannot hide a new Autodesk release signal.

Do not run live watcher mode until the manual gates in `action1/validation-notes.md` are complete. The script enforces Action1 inventory build resolution, manual-version mismatch checks, duplicate version checks, package ID, and token checks; it does not enforce the Action1 match-conflict gate by itself.

## Recommended Deployment

1. Run tests.
2. Build `dist\FusionManagedUpdater.ps1`.
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
