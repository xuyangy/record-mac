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
| Other attached devices | Built-in camera, 1920x1080 |

## Settings

The packaged `PresenterOverlaySpike.app` built from commit 7402d7f, debug configuration,
ad-hoc signature (`Signature=adhoc`, `TeamIdentifier=not set`). `codesign -d -r-` reports
`designated => cdhash H"d8cbe7d1ac553bc384130f991cab0a26e2671b8c"`.

Two `SCStream`s named `clean` and `overlay` over the same display filter, 60 fps, BGRA, cursor
shown, starting on the built-in display. The built-in camera recorded through
`AVCaptureMovieFileOutput`. Presenter Overlay was turned on and changed from the system Video
menu in the menu bar.

## What was recorded

One run of about eight minutes, with ordinary desktop content on screen. The run's
`events.log`, `frames.jsonl` (34,245 complete frames), `summary.json`, `camera-1.mov`, and the
one-per-second PNGs stay on the reference machine under `~/Movies/PresenterOverlaySpike/` and
are not committed; they show the creator and their screen.

In order: Presenter Overlay on, small and large, off, and on again, on the first generation;
Pause and Resume, which start a second generation of both streams; the other stream selected in
the system menu, small and large; Toggle Filter three times; Next Display between the built-in
and external displays, three times; Presenter Overlay off; quit.

## What was checked

1. Every complete frame of each stream, from `frames.jsonl`: `presenterOverlayContentRect`,
   `contentRect`, and pixel size. Pass rule for the two-stream design: no frame of the `clean`
   stream carries an engaged rect (finite and non-empty).
2. The per-stream effect callbacks against the engaged frames.
3. The camera file while the effect is on. Pass rule: the camera recording continues.
4. Camera and screen recording permission state at each launch, from `events.log`.

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

7. The camera file stopped 0.3 s after the effect started, with
   `AVFoundationErrorDomain -11809` ("Recording Stopped") and
   `AVErrorRecordingSuccessfullyFinishedKey` true. `camera-1.mov` holds 81.5 s, up to that
   moment. The window's camera preview showed the Presenter Overlay symbol instead of the
   camera image from then on.
8. No camera recording ran for the rest of the session, about six and a half minutes,
   including the 77 s after the effect stopped. The spike starts a new file only after an
   unsuccessful finish, and it does not log session interruptions, so whether the session
   delivered frames again after the effect stopped was not measured.

### Permissions

9. First launch of the first build: camera `notDetermined`, the prompt was granted; screen
   recording was not granted and shareable content failed with "The user declined TCCs for
   application, window, display capture". After the screen grant, three relaunches started
   with both granted.
10. After a rebuild that changed the code, the first launch reported camera `notDetermined`
    again (granted at the prompt) and screen recording declined. A relaunch after
    `tccutil reset ScreenCapture local.recordmac.presenter-overlay-spike` was still declined.
    After the grant in System Settings, the next launch started with both granted.

### Not run

11. A deliberate denial, a camera switch, and a camera disconnect. These remain outstanding
    under T014, and the full permission record under T055.

## Outcome

Partial run. Fail for the two-stream design: the clean stream carried the composite on 7,762 frames, so a
second stream does not keep the screen track clean. The fallback in research.md R-009 is the
branch taken (T015).

The camera recording also stops when the effect starts. FR-073 and SC-013 require the
separate camera recording in full while Presenter Overlay is on; this run shows the movie file
output does not meet that, and a data-output camera path was not tried.
