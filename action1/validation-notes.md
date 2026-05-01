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

## Package Dry Run and Live Creation

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

The live package was created on 2026-05-01:

```text
Package ID: Autodesk_Autodesk_Fusion_Managed_Updater_1777641192975
Status: Published
```

## Version Dry Run

Action1 version creation dry-run produced a valid request preview for package path:

```text
/software-repository/all/PLACEHOLDER_FUSION_PACKAGE_ID/versions
```

The dry-run body was generated from:

```powershell
New-Action1FusionVersionBody -BuildVersion '2702.1.58' -DetectedDate '2026-05-01' -PayloadFileName 'FusionManagedUpdater.cmd'
```

The live Action1 API rejected per-version `description` and `internal_notes` with HTTP 400. The accepted version body omits both fields; the historical-version warning is carried by the package-level description and internal notes.

Version dry-run request body:

```json
{
  "version": "2702.1.58",
  "app_name_match": "^Autodesk Fusion(?: 360)?$",
  "release_date": "2026-05-01",
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

## Live Version Creation and Upload

Action1 installed software inventory was queried for `Autodesk Fusion`; the highest observed build was `2702.1.58`.

The live version was created on 2026-05-01:

```text
Package ID: Autodesk_Autodesk_Fusion_Managed_Updater_1777641192975
Version ID: 2702.1.58_1777641262894
Version: 2702.1.58
Approval status: New
```

The first live attempts confirmed Action1 rejects these per-version fields:

```text
description
internal_notes
```

The live-created version succeeded after both fields were removed. The generated `dist\FusionManagedUpdater.cmd` payload was uploaded successfully, and the version response now includes a `binary_id.Windows_64` value for the attached file.

## Live Write Preconditions

Before future live Action1 writes:

1. Match-conflict check completed through the direct Action1 API on 2026-05-01 with no blocking or conflicting package matches.
2. Use package ID `Autodesk_Autodesk_Fusion_Managed_Updater_1777641192975` for `Autodesk Fusion Managed Updater`.
3. Set `ACTION1_FUSION_PACKAGE_ID` to the real package ID.
4. Rerun package and version creation dry-runs and confirm both complete without validation errors.
5. Confirm the generated payload is current and under 1 MB.
6. Refresh Action1 installed software inventory and confirm `Autodesk Fusion` or `Autodesk Fusion 360` reports the build you want to record.
7. Confirm the package details response includes `fields=versions`; the watcher uses that response to reject duplicate version creation without advancing state.
8. Confirm the accepted version body still matches the documented shape and continues to omit per-version `description` and `internal_notes`.
9. Record the final match-conflict result and dry-run previews in this file.
10. Proceed with live writes only after the above gates pass.

`FUSION_OBSERVED_BUILD_VERSION` is optional for live watcher runs. If set, it must match the highest Action1 inventory version unless the watcher is run with `-AllowManualObservedBuild`. Use that override only for a documented manual observation, such as a lab endpoint queried directly before Action1 inventory refresh.

If the watcher reports that the resolved build already exists in the Action1 package after an Autodesk release signal changed, refresh Action1 installed software inventory and rerun. The watcher intentionally leaves state unchanged when this happens because Action1 does not expose a writable per-version notes field for idempotent release-signal adoption.
