# Stateless Action1 Fusion Container Design

Date: 2026-05-01

## Purpose

Package the Action1 Fusion release watcher as a container that can run without any manual Action1 setup beyond API credentials. The container should be usable as a one-shot job, a Portainer Edge Job, or a long-running scheduled service.

The Windows endpoint updater remains Windows-specific because it runs on Action1-managed Fusion endpoints. The container is admin-side automation only.

## Goals

- Run on a Linux Docker node.
- Require no persistent volume or local state file.
- Authenticate to Action1 with client credentials.
- Find or create the Action1 custom package by package name.
- Create missing Action1 versions and upload the small Windows payload automatically.
- Treat already-recorded versions as successful no-ops.
- Default to one-shot behavior for easy testing and job schedulers.
- Support long-running scheduled mode with standard environment names reusable by future software-management containers.

## Non-Goals

- Do not run Fusion updates inside the container.
- Do not store Action1 secrets in files.
- Do not require the operator to manually create the Action1 package in the UI.
- Do not rely on a mounted state volume for correctness.
- Do not support manual observed-build overrides in the container interface.
- Do not implement rollback to old Fusion builds.

## Runtime Configuration

Required:

```text
ACTION1_CLIENT_ID=<Action1 OAuth client id>
ACTION1_CLIENT_SECRET=<Action1 OAuth client secret>
```

Optional:

```text
ACTION1_BASE_URL=https://app.action1.com/api/3.0
ACTION1_ORG_ID=all
PACKAGE_NAME=Autodesk Fusion Managed Updater
ONE_SHOT=true
CHECK_FREQUENCY_CRON=
CHECK_FREQUENCY_MINUTES=1440
```

`ONE_SHOT` defaults to `true`. When `ONE_SHOT=false`, the container runs once at startup, then repeats on schedule.

`CHECK_FREQUENCY_CRON` wins when set. If it is empty, the scheduler uses `CHECK_FREQUENCY_MINUTES`. If both schedule settings are unset, the interval is 1440 minutes.

## Package Discovery

The container uses `PACKAGE_NAME`, not a required package ID.

Package handling:

1. Query custom Software Repository packages for the exact package name.
2. If exactly one matching package exists, use its ID.
3. If no matching package exists, create it with platform `Windows`, vendor `Autodesk`, and package-level warning text.
4. If multiple exact matches exist, fail with a clear duplicate-name error.

The package description and internal notes must state that historical versions are release records only and that Autodesk's live streamer controls the actually installable build.

## Stateless Idempotency

Action1 is the durable state source. The container does not need a local state file.

Each run:

1. Authenticates to Action1.
2. Ensures the package exists.
3. Queries Action1 installed software inventory for `Autodesk Fusion`.
4. Resolves the highest observed Fusion version from inventory entries named `Autodesk Fusion` or `Autodesk Fusion 360`.
5. Queries the package versions.
6. If the resolved version already exists and has `binary_id.Windows_64`, logs an already-recorded message and exits successfully.
7. If the resolved version already exists without `binary_id.Windows_64`, uploads `FusionManagedUpdater.ps1` to repair the incomplete version.
8. If the resolved version does not exist, creates the version and uploads `FusionManagedUpdater.ps1`.

This means container restarts or repeated cron runs may perform extra API reads, but they should not fail solely because a version has already been recorded.

## Version Creation

The version body must match the fields accepted by the live Action1 API:

- `version`
- `app_name_match`
- `release_date`
- `security_severity`
- `silent_install_switches`
- `success_exit_codes`
- `reboot_exit_codes`
- `install_type`
- `update_type`
- `os`
- `file_name`

Per-version `description` and `internal_notes` must not be sent because the live API rejects them.

The created version remains at Action1's default approval status. The container does not approve deployments.

## Payload Upload

After creating a new version, the container uploads the generated `FusionManagedUpdater.ps1` to the created version's Windows 64-bit file slot.

The upload flow uses the Action1 direct API because the connector could not provide the required upload headers:

1. Start upload with content type `application/octet-stream`, payload length, and JSON content type.
2. Read `X-Upload-Location`.
3. PUT the full payload with `Content-Range`.
4. Confirm the version response includes `binary_id.Windows_64`.

The container updates nothing else after a failed upload. A future run should either retry against the existing version if no binary is attached or fail with a clear repair message.

## Scheduler Behavior

One-shot mode:

1. Run the automation once.
2. Exit `0` for no-op or successful create/upload.
3. Exit nonzero for configuration, Action1 API, Action1 inventory, or upload failures.

Long-running mode:

1. Run immediately at startup.
2. Log success or failure.
3. Sleep until the next scheduled run.
4. Repeat while the container process is alive.

Fatal configuration errors should terminate the container. Transient Action1/API errors in long-running mode should be logged and retried at the next scheduled run.

## Docker Artifacts

Add:

- `Dockerfile`
- `docker-compose.example.yml`
- container entrypoint script

The image should use a Linux PowerShell base image so existing watcher logic can be reused under `pwsh`.

The basic Compose example should only require credentials. `PACKAGE_NAME` should be shown as an optional override.

## Testing Strategy

Tests should cover:

- `ONE_SHOT` parsing and default behavior.
- schedule selection priority between cron and minute interval.
- client-credentials token request body.
- package lookup exact-match behavior.
- package auto-create when missing.
- duplicate package-name failure.
- already-recorded version no-op.
- existing version without attached binary repair.
- version creation body omits rejected fields.
- upload init and upload request headers.
- upload confirmation through `binary_id.Windows_64`.

Existing Windows endpoint updater tests stay in place. Container tests should not require real Action1 credentials.

## Implementation Notes

The existing script can keep optional `StatePath` support for non-container use, but Docker docs and defaults should not require it.

The README should describe the container as stateless and idempotent. It should also explain that `PACKAGE_NAME` is a display name used to discover or create the Action1 custom package, not the software detection name. Fusion detection remains controlled by the package version's `app_name_match`.
