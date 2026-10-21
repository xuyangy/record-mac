# Contract: Project Format

How a RecordingProject is laid out on disk. Versioned, with migration required (FR-062).

## Layout

```text
<name>.recordmac/
├── project.json          # manifest: id, formatVersion, displayName, createdAt, source,
│                         # pauses, endReason, overlaidRanges, media tracks and segments
├── media/
│   ├── screen-1.mov      # one file per screen segment (screen-2.mov, … after each size
│   │                     # or pixel-format change)
│   ├── camera-1.mov      # present only if the camera was on; one file per camera
│   │                     # segment (camera-2.mov, … after each switch)
│   ├── microphone-1.m4a  # one file per microphone segment (microphone-2.m4a, … after a
│   │                     # format change, device change, or interruption)
│   ├── system-1.m4a      # one file per system audio segment, by the same rule
│   └── presenter-composite-1.mov  # present only if the creator kept the overlay composite;
│                                  # one file per stretch the overlay was on
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
6. **Segments are explicit.** Every media file is listed in `project.json` with its segment's
   `start` and `end` on the capture clock. Gaps between segments are stored as gaps. A
   `presenter-composite-N.mov` never extends `sourceDuration`, which is measured over the screen,
   camera, and audio tracks only.

## Migration

Each format version ships a migration to the next. Migrations run on open, in order. Media is
never migrated, only the edit document and manifest — which is possible precisely because media
is immutable.

`edit.json` and `project.json` change together, so a migration is one recoverable commit:

1. Write `edit.json.bak` and `project.json.bak`.
2. Write `migration.json` naming the source and target versions.
3. Write the migrated `edit.json`, then the migrated `project.json`, each atomically. The
   manifest goes last because its `formatVersion` is what marks the migration done.
4. Delete `migration.json`, then the backups.

Opening a project that still has `migration.json` means a migration was interrupted: restore
both files from the backups, delete `migration.json`, and run the migration again. A project is
therefore never read with an `edit.json` from one version and a `project.json` from another.

## Test obligations

- Round-trip: write a project, read it back, compare every field, including segments, gaps, and
  `overlaidRanges`.
- Migration: a fixture project at each historical version opens at the current version.
- Atomicity: an interrupted write leaves the previous `edit.json` or `project.json` intact.
- Migration recovery: interrupting after each step of the migration commit, including between
  the two file replacements, reopens to a consistent project at the target version.
- Immutability: after a full editing session, media file hashes are unchanged.
