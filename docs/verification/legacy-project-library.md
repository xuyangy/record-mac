# Verification record: native legacy project library, part 1

**Task or change**: T056 (part 1; T056 stays open)

**Date**: 2026-10-30

## Host

| Item | Value |
|---|---|
| Model | MacBook Pro (Mac17,8) |
| Chip | Apple M5 Pro |
| macOS | 27.0.1 (26A434) |
| Display and mode | not used by this check |
| Other attached devices | not used by this check |

## Settings

Debug build, Xcode toolchain (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`).
Each test uses its own temporary folders; the Rust service is neither built nor run. Behaviour is
compared with open-recorder's `apps/rust-service/src/main.rs` and its tests at `afa3176`.

## What part 1 covers

- `LegacyProjectLibraryStore` handles the project library requests the app sends today:
  `paths`, `prepareRecordingFile`, `registerRecording`, `registerScreenshot`, `saveProject`,
  `updateProject`, `listProjects`, `forgetProject`, and `rememberScreenshot`. It reads and
  writes the same files as the Rust service.
- `LegacyLibraryLocations.forHome` puts the library under `AppVariant.storageDirectoryName`, so
  the production and nightly libraries are separate.
- `LegacyProjectRequest` reads a request's JSON parameters. String fields count only when they
  are strings. `editorState` and `recordingSession` are kept as the caller's JSON.

## Not covered by part 1

- Switching `AppModel`'s callers to the store, a native `health` payload, and removing
  `RustServiceClient.swift` and `RustServiceClientTests.swift` (part 2).

## What was checked

`swift test --filter LegacyProjectLibraryStoreTests` in `apps/macos`, 32 tests, three runs:

1. Locations: production and nightly folders differ and use this app's names; `paths` creates
   the folders and an empty index; prepared recording files are sanitised into the recordings
   folder.
2. Requests: non-string fields are ignored, a JSON `null` editor state is kept, a non-object is
   refused, and a missing path is an error.
3. Saving and updating: editor state and recording session, including unknown fields, are
   written as given and kept when an update leaves them out. Creation time, ID, and last-opened
   time are kept. Updates never duplicate an entry. A screenshot path is kept. With a damaged
   index, nothing changes. With an index that can be read but not replaced, the document's
   original bytes are restored, and an unindexed document gets no marker. An unindexed document
   that already has a marker keeps it when either the document or the index cannot be replaced,
   and is still listed afterwards. When the index write
   fails, a new document is removed. 24 concurrent registrations, each from its own store, are
   all indexed with unique IDs and paths.
4. Availability: available, missing media, missing project, both missing, and unavailable
   (corrupt document, a folder as media, no media path).
5. Forgetting and recovery:
   - Forgetting removes the entry and its marker but keeps the document. With an unreadable
     tombstone list, the index is left as it was.
   - An unmarked loose document is not added to a healthy index. A marked one is recovered
     once and keeps its marker.
   - A marked document indexed under another spelling of its path is not added twice.
   - A forgotten document that is updated again is marked, and it survives a lost index.
   - Salvage with no readable index or backup keeps tombstoned projects out. A stale backup is
     completed from the documents without bringing back forgotten projects. A corrupt index is
     repaired from a fresh backup, keeping IDs.
   - An index removed from an existing library is recovered, not replaced with an empty one, and
     changes fail until then.
   - An unreadable index with nothing to recover is an error.
   - Index entries without `availability` still decode.
6. Screenshots: a screenshot project is remembered and keeps its state. The recent list reads
   newest first by numeric time, with stable IDs, and skips entries without a path. It keeps
   the latest 100, with no duplicates.

To check that the tests can fail, two faults were put in, one at a time, each for one run.
With the document restore removed, both restore tests failed. With a failed update removing any
marker, the marker test failed for both cases. Each fault was then removed.

The full suite (`swift test`) and `scripts/check-no-network.sh` also ran.

## Observations

On macOS, an immutable index file can be read, but renaming another file over it fails. This is
how the tests make the index readable but impossible to replace.

All 32 tests passed in each of three runs. The full suite ran 1046 tests, 6 skipped, none
failed. The network check passed.

## Outcome

Pass for part 1. Part 2 is still to do: switching the callers and removing the Rust service
client.
