# Action1 Validation Notes

Date: 2026-04-30

## Match Conflict Check

Attempted Action1 match-conflict check with:

```text
^Autodesk Fusion(?: 360)?$
```

The Action1 connector returned a structured-content shape error before exposing the API result:

```text
Invalid input: expected record, received array
```

Package creation should still run the match-conflict check again before the first live Action1 write.

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

