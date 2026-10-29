# Verification record: Presenter Overlay spike run

**Task or change**: T014

**Date**: 2026-10-29

## Host

| Item | Value |
|---|---|
| Model | MacBook Pro (Mac17,8) |
| Chip | Apple M5 Pro |
| macOS | 27.0.1 (26A434) |
| Display and mode | Built-in Liquid Retina XDR, captured at 2624x1696 pixels (1312x848 points); DELL U3419W, captured at 3440x1440 |
| Other attached devices | Built-in camera, 1920x1080; no other camera |

## Settings

The packaged `PresenterOverlaySpike.app`, debug configuration, ad-hoc signature
(`Signature=adhoc`, `TeamIdentifier=not set`), in two sessions:

| Session | Spike source | Designated requirement (`codesign -d -r-`) | Camera output |
|---|---|---|---|
| 1 | commit 7402d7f | `cdhash H"d8cbe7d1ac553bc384130f991cab0a26e2671b8c"` | `AVCaptureMovieFileOutput` |
| 2 | commit 8fe628a | `cdhash H"f71cd1da04518fceb964c1a0bf848deb5838750e"` | per run: `AVCaptureVideoDataOutput`, `AVCaptureMovieFileOutput`, or both (`--camera-output`) |

Two `SCStream`s named `clean` and `overlay` over the same display filter, 60 fps, BGRA, cursor
shown, starting on the built-in display. Presenter Overlay was turned on and changed from the
system Video menu in the menu bar. In session 2 the data output only counts each second's
camera buffers, drops, presentation-time gaps, and dimensions (`camera-frames.jsonl`); it
neither writes nor inspects camera images.

## What was recorded

Every run's files stay on the reference machine under `~/Movies/PresenterOverlaySpike/` and are
not committed; they show the creator and their screen.

Session 1: one run of about eight minutes, with ordinary desktop content on screen
(`events.log`, `frames.jsonl` with 34,245 complete frames, `summary.json`, `camera-1.mov`, and
one-per-second PNGs). In order: Presenter Overlay on, small and large, off, and on again, on the
first generation; Pause and Resume, which start a second generation of both streams; the other
stream selected in the system menu, small and large; Toggle Filter three times; Next Display
between the built-in and external displays, three times; Presenter Overlay off; quit.

Session 2: three camera runs and the permission sequence below.

| Run | Camera output | Sequence |
|---|---|---|
| A | data | on (small), large, off, on, off |
| B | movie | on (small), large, off, on, off |
| C | movie and data | on (small); Pause and Resume, which stopped the effect; on and off three times |

## What was checked

1. Every complete frame of each stream, from `frames.jsonl`: `presenterOverlayContentRect`,
   `contentRect`, and pixel size. Pass rule for the two-stream design: no frame of the `clean`
   stream carries an engaged rect (finite and non-empty).
2. The per-stream effect callbacks against the engaged frames.
3. The camera file while the effect is on. Pass rule: the camera recording continues.
4. Session 2: per second, the data output's buffers, drops, largest presentation-time gap, and
   dimensions, against the effect callbacks; the movie output's start and finish events.
5. Camera and screen recording permission state at each launch, from `events.log`.

## Observations

### Which stream the system composites

| Stream | Generation | Complete frames | Engaged frames | Effect starts / stops |
|---|---|---|---|---|
| clean | 1 | 8,307 | 7,762 | 2 / 2 |
| overlay | 1 | 2,823 | 0 | 0 / 0 |
| clean | 2 | 10,450 | 0 | 0 / 0 |
| overlay | 2 | 12,665 | 8,894 | 1 / 1 |

1. The system applies the effect to one stream at a time and chooses that stream itself. On the
   first generation it composited `clean`, the stream started first, and `overlay` stayed
   unengaged. On the second generation, after the other stream was selected in the system menu,
   it composited `overlay`, and `clean` stayed unengaged on both displays.
2. `outputVideoEffectDidStart(for:)` and `outputVideoEffectDidStop(for:)` arrived on the
   composited stream only, and each engaged run of frames lies between a start and its stop.
3. Small: the attachment equals the full content rect, `[0, 0, 1312, 848]` on the built-in
   display and `[0, 0, 3440, 1440]` on the external one.
4. Large: `contentRect` changes to a 16:9 area inside the frame (`[0, 55, 1312, 738]` built-in,
   `[440, 0, 2560, 1440]` external) and the attachment is a smaller rect inside it
   (`[36.9, 91.9, 761.2, 492.0]` built-in, `[512, 72, 1706.7, 714.4]` external). On the built-in
   display its x moves between 36.9 and 513.9 in short animations.
5. While the effect is on, the attachment reads `CGRect.null` for runs of about one second
   when the effect changes size. The attachment alone therefore does
   not mark every frame the effect touches; the effect callbacks bracket them.
6. Toggle Filter and Next Display update both streams' filters without a new effect start or
   stop.

### Camera

7. Session 1: the camera file stopped 0.3 s after the effect started, with
   `AVFoundationErrorDomain -11809` ("Recording Stopped") and
   `AVErrorRecordingSuccessfullyFinishedKey` true. `camera-1.mov` holds 81.5 s, up to that
   moment. The window's camera preview showed the Presenter Overlay symbol instead of the
   camera image from then on.
8. No camera recording ran for the rest of the session, about six and a half minutes,
   including the 77 s after the effect stopped. The spike starts a new file only after an
   unsuccessful finish, and it does not log session interruptions, so whether the session
   delivered frames again after the effect stopped was not measured.
9. Session 2, movie output (runs B and C): the file stopped on every one of six effect starts,
   0.07 to 0.44 s after it, each time with -11809 and successfully finished. The capture session
   kept running, the camera was never reported in use by another application, and no
   interruption or runtime error was logged. No movie recording resumed before the effect
   stopped. After four of the six effect stops a new file started about 1.7 s later; after
   the stop caused by Pause the new file started on Resume, about 12.7 s later, and after the
   last stop the spike's limit of three restarts had been reached, so none started.
10. Session 2, data output (runs A and C): buffers arrived through every effect span at about
    30 per second and 1920x1080, with no drop reported and no second without a buffer: 4,677
    buffers in run A (2,478 with the effect on) and 6,139 in run C. In each run the
    presentation times jump once, by 0.569 s (run A) and 0.566 s (run C), within a second of
    the first effect start; every other gap is about 0.05 s or less, including across the repeated
    activations in run C. The effect stopping does not interrupt the data output.
11. Pause stops both screen streams, which ends the effect; after Resume the new streams start
    without it.

### Permissions

12. First launch of the first build: camera `notDetermined`, the prompt was granted; screen
   recording was not granted and shareable content failed with "The user declined TCCs for
   application, window, display capture". After the screen grant, three relaunches started
   with both granted.
13. After each rebuild that changed the code, the first launch reported camera `notDetermined`
    (granted at the prompt) and screen recording declined, with no prompt. In session 2 System
    Settings still showed the app's screen recording switch on; turning it off and on, and a
    relaunch, left it declined. After
    `tccutil reset ScreenCapture local.recordmac.presenter-overlay-spike` the next launch showed
    the system prompt; the grant in System Settings, confirmed with Touch ID or the password,
    took effect at the next launch.
14. Denial, session 2: after both permissions were reset, the camera prompt was answered Don't
    Allow and the screen recording prompt Deny. The camera reported `denied` and screen
    recording stayed declined. The relaunch showed no prompt: the camera request returned false
    at once. After both were turned on in System Settings, the next launch started with both
    granted.

### Not run

15. A camera switch and a camera disconnect: the reference machine has one camera. These
    remain outstanding under T014, and the full permission record under T055.
16. Writing the data output's buffers to a file, and checking that the camera image is the
    uncomposited camera, plays back, and aligns with the screen and audio tracks.

## Outcome

Partial run. Fail for the two-stream design: the clean stream carried the composite on 7,762
frames, so a second stream does not keep the screen track clean. The fallback in research.md
R-009 is the branch taken (T015).

Camera: the movie file output ends shortly after each effect start and does not continue
through the effect span, so it cannot meet FR-073 and SC-013. The data output keeps delivering buffers, with one presentation-time gap of
about 0.57 s after the first effect start in each of the two measured runs. That gap is a loss
of camera time under FR-073, which allows no camera gap; it stays open. Whether the delivered
buffers make a usable, uncomposited, aligned camera recording is unverified.
