# Contract: Project Format

How a RecordingProject is laid out on disk. Versioned, with migration required (FR-062).

## Layout

```text
<name>.recordmac/
├── project.json          # manifest: id, formatVersion, displayName, createdAt, source,
│                         # pauses, endReason
├── media/
│   ├── screen.mov
│   ├── camera-1.mov      # present only if the camera was on; one file per
│   │                     # camera segment (camera-2.mov, … after each switch)
│   ├── microphone.m4a
│   ├── system.m4a
│   └── presenter-composite.mov  # present only if the creator kept the overlay composite
├── activity.json         # the frozen ActivityStream and its GeometrySegments
└── edit.json             # the EditDocument
```

## Rules

1. **Write-once capture.** Files under `media/` and `activity.json` are written during capture and
   never modified afterwards. An editing operation that would rewrite them is a defect
   (Principle I, FR-050).
2. **Two mutable files, both atomic.** `edit.json` is rewritten by autosave (FR-049).
   `project.json` is rewritten only to rename (`displayName`) or migrate (`formatVersion`). Both
   are written to a temporary file, then replaced, so an interrupted write cannot corrupt a
   project.
3. **Self-contained.** A project directory can be moved or copied without breaking. All internal
   references are relative.
4. **Versioned.** `formatVersion` is an integer in `project.json`. Opening a project with a lower
   version must migrate it; opening one with a higher version must refuse clearly rather than
   partially read it.
5. **Deletion is whole.** Removing a project removes the directory, so media and edits cannot be
   orphaned from each other (FR-060).

## Migration

Each format version ships a migration to the next. Migrations run on open, in order, and write a
backup of `edit.json` and `project.json` before the first one runs. Media is never migrated, only the edit document
and manifest — which is possible precisely because media is immutable.

## Test obligations

- Round-trip: write a project, read it back, compare every field.
- Migration: a fixture project at each historical version opens at the current version.
- Atomicity: an interrupted write leaves the previous `edit.json` or `project.json` intact.
- Immutability: after a full editing session, media file hashes are unchanged.
