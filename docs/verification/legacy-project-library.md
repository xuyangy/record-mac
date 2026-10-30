# Verification record: native legacy project library

**Task or change**: T056

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

## What is covered

- `LegacyProjectLibraryStore` handles the project library requests the app sends today:
  `paths`, `prepareRecordingFile`, `registerRecording`, `registerScreenshot`, `saveProject`,
  `updateProject`, `listProjects`, `forgetProject`, and `rememberScreenshot`. It reads and
  writes the same files as the Rust service.
- `LegacyLibraryLocations.forHome` puts the library under `AppVariant.storageDirectoryName`, so
  the production and nightly libraries are separate.
- `LegacyProjectRequest` reads a request's JSON parameters. String fields count only when they
  are strings. `editorState` and `recordingSession` are kept as the caller's JSON.
- `AppModel` takes a `LegacyProjectLibraryStore` (default `.standard()`) and uses it for
  refresh, paths, recording-file preparation, captured and imported media registration,
  autosave, forgetting a project, and remembering a screenshot. Disk work stays off the main
  actor. When registration fails before the library's paths have loaded, the local recovery
  project goes to the store's projects folder. Refresh reports `HealthPayload.native`, and the ready message is `Library ready`.
- Inside a test process, `.standard()` gives each call a new temporary folder.
- `RustServiceClient.swift` and its tests are removed. The tests of its pipe buffering and
  process time-outs have no replacement, since no helper process remains.

## What was checked

`swift test --filter 'LegacyProjectLibraryStoreTests|AppModelNativeLibraryTests|AppVariantTests|AppPresentationStateMachineTests|ProjectLibraryAndSettingsViewStateTests|AppModelStateTests'`
in `apps/macos`, 149 tests, three runs. Items 1 to 6 are `LegacyProjectLibraryStoreTests`
(32 tests):

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

7. `AppModelNativeLibraryTests`, each with a library in its own temporary folder:
   - Refresh loads the library's paths and projects, reports native health and `Library
     ready`; a damaged library with no backup is reported as a failure.
   - A screenshot taken through the model is registered as a project and remembered in the
     recent list, with its editor state.
   - Importing the same video twice, the second time from a new model with no loaded projects,
     makes one project.
   - An import whose registration fails, on a model whose paths have not loaded, writes its
     recovery project and marker into the injected library, where listing finds it.
   - Autosave updates the document's title and editor state and keeps its ID and creation time.
   - In a test process, `.standard()` gives a new temporary folder on each call, not one under
     the user's `Library`.
8. `AppVariantTests`: only the nightly bundle identifier selects `RecordMacNightly`, and a
   shell variable cannot change it. The settings and presentation tests expect `Library ready`.
   The fallback tests in `AppModelStateTests` make registration fail on purpose, so they still
   check the local recovery path.

To check that the tests can fail, two faults were put in, one at a time, each for one run.
With the document restore removed, both restore tests failed. With a failed update removing any
marker, the marker test failed for both cases. With the recovery project sent to another temporary folder,
the failed-import test failed. Each fault was then removed.

The full suite (`swift test`) and `scripts/check-no-network.sh` also ran.

## Observations

On macOS, an immutable index file can be read, but renaming another file over it fails. This is
how the tests make the index readable but impossible to replace.

All 149 tests passed in each of three runs. The network check passed.

The full suite ran 1048 tests: 6 skipped and 1 failed. The failed test is
`TargetResolverTests.testAControlledButtonResolvesThroughTheSystem`. It opens a real window and
hit-tests its button on screen. The session was locked during the run
(`CGSSessionScreenIsLocked` was true), so the button was not on screen. This change does not touch
that test or the resolver. The full suite is therefore not a pass. A run in an unlocked session
is still needed to close the live Accessibility check. After the runs, the user's library under
`~/Library/Application Support/Record Mac/Projects` had no file changed.

## Outcome

Pass for the native library. The app's legacy project library runs natively, with no Rust
service. The live Accessibility test in the full suite is open until an unlocked-session run.
