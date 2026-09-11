# Contract: Project Format

How a RecordingProject is laid out on disk. Versioned, with migration required (FR-062).

## Layout

```text
<name>.recordmac/
├── project.json          # manifest: id, formatVersion, displayName, createdAt, source
├── media/
│   ├── screen.mov
│   ├── camera.mov        # present only if the camera was on
│   ├── microphone.m4a
│   └── system.m4a
├── activity.json         # the frozen ActivityStream
└── edit.json             # the EditDocument — the only file rewritten after capture
```

## Rules

1. **Write-once media.** Files under `media/` and `activity.json` are written during capture and
   never modified afterwards. An editing operation that would rewrite them is a defect
   (Principle I, FR-050).
2. **`edit.json` is the only mutable file.** Autosave rewrites it atomically: write to a
   temporary file, then replace, so an interrupted save cannot corrupt a project (FR-049).
3. **Self-contained.** A project directory can be moved or copied without breaking. All internal
   references are relative.
4. **Versioned.** `formatVersion` is an integer in `project.json`. Opening a project with a lower
   version must migrate it; opening one with a higher version must refuse clearly rather than
   partially read it.
5. **Deletion is whole.** Removing a project removes the directory, so media and edits cannot be
   orphaned from each other (FR-060).

## Migration

Each format version ships a migration to the next. Migrations run on open, in order, and write a
backup of `edit.json` before the first one runs. Media is never migrated, only the edit document
and manifest — which is possible precisely because media is immutable.

## Test obligations

- Round-trip: write a project, read it back, compare every field.
- Migration: a fixture project at each historical version opens at the current version.
- Atomicity: an interrupted autosave leaves the previous `edit.json` intact.
- Immutability: after a full editing session, media file hashes are unchanged.
