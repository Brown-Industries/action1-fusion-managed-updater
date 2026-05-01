# Action1 Validation Notes

Date: 2026-05-01

## Match Conflict Check

Attempted Action1 match-conflict check with:

```text
^Autodesk Fusion(?: 360)?$
```

The Action1 connector returned a structured-content shape error before exposing the API result:

```text
Invalid input: expected record, received array
```

This was observed through the `action1_check_package_match_conflicts` connector tool.

The same check was rerun through the direct Action1 REST API on 2026-05-01:

```text
GET /software-repository/all/match-conflicts?app_name_match=%5EAutodesk%20Fusion%28%3F%3A%20360%29%3F%24
```

Result:

```json
[]
```

The direct API returned HTTP 200 with an empty conflict array. No blocking or conflicting package matches were found for `^Autodesk Fusion(?: 360)?$`.

## Package Dry Run

Action1 package creation dry-run produced a valid request preview for:

```json
{
  "name": "Autodesk Fusion Managed Updater",
  "vendor": "Autodesk",
  "description": "Small Action1-managed updater for Autodesk Fusion. Historical versions are release records only; Autodesk's live streamer controls the actual installable build.",
  "platform": "Windows",
  "internal_notes": "Do not use this package for rollback. Deployments run Autodesk's currently available Fusion streamer update."
}
```

## Version Dry Run

Action1 version creation dry-run produced a valid request preview for package path:

```text
/software-repository/all/PLACEHOLDER_FUSION_PACKAGE_ID/versions
```

The dry-run body was generated from:

```powershell
New-Action1FusionVersionBody -BuildVersion '2702.1.58' -DetectedDate '2026-04-30' -PayloadFileName 'FusionManagedUpdater.cmd'
```

The generated body includes the historical-version warning in both `description` and `internal_notes`.

Version dry-run request body:

```json
{
  "version": "2702.1.58",
  "app_name_match": "^Autodesk Fusion(?: 360)?$",
  "description": "This version records Autodesk Fusion build 2702.1.58 as detected on 2026-04-30. Fusion is delivered by Autodesk's live streamer endpoint. Deploying this or any older version will update the endpoint to Autodesk's currently available Fusion build, not necessarily this historical build. Only the latest Autodesk-served Fusion build is installable through this package.",
  "internal_notes": "This version records Autodesk Fusion build 2702.1.58 as detected on 2026-04-30. Fusion is delivered by Autodesk's live streamer endpoint. Deploying this or any older version will update the endpoint to Autodesk's currently available Fusion build, not necessarily this historical build. Only the latest Autodesk-served Fusion build is installable through this package.",
  "release_date": "2026-04-30",
  "security_severity": "Unspecified",
  "silent_install_switches": "",
  "success_exit_codes": "0",
  "reboot_exit_codes": "",
  "install_type": "exe",
  "update_type": "Regular Updates",
  "os": [
    "Windows 10",
    "Windows 11"
  ],
  "file_name": {
    "Windows_64": {
      "type": "cloud",
      "name": "FusionManagedUpdater.cmd"
    }
  }
}
```

`PLACEHOLDER_FUSION_PACKAGE_ID` in the dry-run path must be replaced with the created Action1 package ID before live version creation.

## Live Write Preconditions

Before any live Action1 write:

1. Match-conflict check completed through the direct Action1 API on 2026-05-01 with no blocking or conflicting package matches.
2. Create or identify the real Action1 package ID for `Autodesk Fusion Managed Updater`.
3. Replace `PLACEHOLDER_FUSION_PACKAGE_ID` with the real package ID.
4. Rerun package and version creation dry-runs and confirm both complete without validation errors.
5. Confirm the generated payload is current and under 1 MB.
6. Refresh Action1 installed software inventory and confirm `Autodesk Fusion` or `Autodesk Fusion 360` reports the build you want to record.
7. Confirm the package details response includes `fields=versions`; the watcher uses that response to reject duplicate version creation without advancing state unless the existing version has the same Autodesk release-signal fingerprint.
8. Confirm the accepted version body still matches the documented shape and retains the historical-version warning in `description` or `internal_notes`. Live watcher-created versions also append a `FusionManagedUpdaterReleaseSignal` fingerprint to `internal_notes` for idempotent retry recovery.
9. Record the final match-conflict result and dry-run previews in this file.
10. Proceed with live writes only after the above gates pass.

`FUSION_OBSERVED_BUILD_VERSION` is optional for live watcher runs. If set, it must match the highest Action1 inventory version unless the watcher is run with `-AllowManualObservedBuild`. Use that override only for a documented manual observation, such as a lab endpoint queried directly before Action1 inventory refresh.

If the watcher reports that the resolved build already exists in the Action1 package after an Autodesk release signal changed, refresh Action1 installed software inventory and rerun. The watcher intentionally leaves state unchanged unless the existing Action1 version carries the same release-signal fingerprint as the current Autodesk HEAD.
