# FrameCraft: handoff for another AI assistant

Give this whole file to a new AI chat to continue the project. Status as of 2026-10-22, commit `5c6168e`.

## What the app is

**FrameCraft** is a native iPhone camera app written in SwiftUI. Its features are modeled on the publicly visible feature set of the App Store app *Framed — Take Aesthetic Photos*:

- a real camera
- composition guidance: a scan that suggests a framing and coaches you to it
- original film looks
- a non-destructive editor
- an in-app photo library
- export with frames and a date stamp

The visual style (dark Liquid Glass camera chrome, yellow accents) comes from the owner's other app, **Camera Glass Pro**.

- **Repo:** https://github.com/smokerzew/framecraft (public, branch `main`)
- **Local folder (owner's Windows PC):** `E:\workclaude\framecraft`
- **Bundle ID:** `com.smokerzew.FrameCraft`. It installs next to Camera Glass Pro, not over it.
- **Minimum iOS:** 18.0. Swift 5 language mode, built with Xcode 26.
- **Size:** about 8,800 lines of Swift and Metal, plus a unit-test suite.

## Rules from the owner (follow these)

1. **FrameCraft and Camera Glass Pro are separate apps.** Never add FrameCraft features to Camera Glass Pro (repo `smokerzew/camera-glass-pro`, folder `E:\workclaude\camera_glass_pro`). The owner reacted strongly when that happened once, and it was fully reverted.
2. **Match how Framed behaves, without copying its brand.** Use original names for looks, frames and text. Never use Framed's preset names (Sienna, Archive, Clean-as-theirs, Harbor, Dusk, Press, Album, Amber, Silver, Relic, Mono…), logos or artwork. FrameCraft's own names are listed below.
3. **Make features actually work.** No fake buttons or simulated results. If the hardware can't do something, disable it and say why.
4. **Only claim what has been verified.** Keep these levels apart: source written, CI build passed, IPA packaged, installed on a device, tested on a device. As of now nothing has been tested on a real iPhone, and the Simulator has no camera.
5. **The owner has no Mac.** All code is written on Windows, and builds run only on GitHub Actions.
6. **Write in plain language for the owner.** Keep messages short and clear.

## How it's built and installed

- `project.yml` is an **XcodeGen** spec. The `.xcodeproj` is generated in CI and is not committed.
- The workflow `.github/workflows/build-ios-ipa.yml` runs on the `macos-26` runner, on every push to `main`. It:
  1. selects the newest Xcode 26
  2. installs XcodeGen and runs `xcodegen generate`
  3. runs the unit tests on an iPhone simulator
  4. builds an unsigned Release device app
  5. checks that the app contains its binary and `default.metallib`
  6. zips `Payload/FrameCraft.app` into `FrameCraft.ipa` and publishes it to the release tagged **`latest`**
- **Download:** `https://github.com/smokerzew/framecraft/releases/download/latest/FrameCraft.ipa` (no sign-in needed). Copies are kept in `dist\FrameCraft.ipa` and `C:\Users\lucab\Downloads\FrameCraft.ipa`.
- **Install:** the owner installs it with **Sideloadly** using a free Apple ID (see `docs/SIDELOADLY_INSTALL.md`).
  - Free IDs allow only **3 sideloaded apps** on the phone at once.
  - Free-ID installs expire after 7 days.
- **Reading CI without the `gh` CLI** (it isn't installed):
  1. Poll `https://api.github.com/repos/smokerzew/framecraft/commits/<sha>/check-runs`.
  2. On failure, read `.../check-runs/<id>/annotations`. The workflow turns compile and test errors into annotations, which can be read without signing in.
  3. Anonymous API access allows 60 requests per hour, so poll every 90–120 seconds.
- **Git identity:** set in the repo's local config (`lucab`). Commits end with a `Co-Authored-By` line.

## Architecture (folder `FrameCraft/`)

| Folder | What's there |
|---|---|
| `App/` | `FrameCraftApp.swift`: `RootView` shows `CameraScreen`, with `EditorView` over it while a photo is open. |
| `Settings/` | `Settings.swift`: settings keys, `GridStyle`, `FlashSetting`, `TimerSetting`, `CaptureAspect` (3:4, 4:5, 9:16, 1:1), `CameraMode` (PHOTO, CUSTOM), `ZoomLimits`, environment values, `SplitMix64`, `AppAlert`. |
| `UI/` | Glass components reused from Camera Glass Pro: `cameraGlass` modifier, `GlassIconButton`, `PanelControlButton`, `GlassTabs`, `ZoomSelector`, `ZoomDial`, `FocusBox`, grid and level overlays, `CameraModeSelector` (the sliding mode capsule). |
| `Camera/` | `CameraService` (all AVFoundation work; see below), `LiveCameraModel` (`@Observable @MainActor` camera state: status, capabilities, zoom, exposure, manual settings, readings, RAW, scan phases, live coach, custom frame, tracking), `CameraPreviewView` (preview layer plus `LiveLookRenderer`, a Metal view that shows the chosen look on live frames). |
| `Composition/` | `CompositionEngine` (crop-style scoring, used by "crop" fallbacks, plus `AspectFillMapping`), `FramingCoach` (live framing plans and advice; see below), `SceneAnalyzer` (Vision; `SubjectTracker`; `FrameRouter`, which sends frames to scan, live and tracking analysis on its own queue), `ShotDirector` (names the subject, writes the instruction). |
| `Imaging/` | `PhotoRenderer` (one Core Image pipeline for preview, live look and export), `FilmLooks` (`FilmLook` enum plus `LookRecipe`), `FilmDamage` (dust and scratches), `AutoEdit` (the edit a new capture opens with), `Kernels.metal` (filmGrain, halationSource, halationAdd, lookSplitTone, colorGrade). |
| `Models/` | `EditState` (every edit as Codable data, tolerant decoder), `EditParameter` (slider definitions), `ColorMixer` (HSL as a 32³ lookup table), `ToneCurves` and `ColorCalibration`, `EditSession` (the open photo: preview, undo/redo, render loop, autosave), `AppModel` (top-level state, controls, capture → project → editor, library). |
| `Editor/` | `EditorView` (Looks · Adjust · Effects · Frames, `RulerSlider`, tool rows, Delete / undo / redo / Save), `CurvesSection` (also holds `CalibrationSection`), plus sheets for HSL, grading and crop. |
| `Library/` | `ProjectStore` (Application Support/Projects/<id>/: original file, `project.json` with the `EditState` and `FinishSettings`, `thumb.jpg`), `LibraryView`. |
| `Export/` | `ExportService` (full-resolution render from the original, finish, carried-over EXIF with optional location removal, JPEG/HEIF 10-bit/PNG 16-bit, Save to Photos), `FinishingRenderer` (frames and the date stamp; `CaptureMetadata` reads real EXIF and never invents values), `ExportSheet`. |
| `Views/` | `CameraScreen` (status row, viewfinder, shutter controls, bottom bar, pop-ups, hold-still badge, scan button), `LiveViewfinderView` (preview, guides, coach overlay, custom-frame dragging, permission and error cards), `LiveCameraControls` (custom-frame bar, manual controls pop-up), `ExposureStrip` (with `TickRuler`), `ControlPanel` (⠿ CAMERA/PRO pages, plus `LookPicker` and `LookTile`). |

### Camera (`CameraService`)

- Uses the best available device: triple → dual-wide → dual → wide camera on the back, TrueDepth → wide on the front.
- Session preset `.photo`, with the largest `maxPhotoDimensions` and quality prioritization.
- ProRAW is enabled when the device supports it. Bayer RAW and ProRAW are captured as DNG together with a processed HEIF.
- Video data output (BGRA, rotated to portrait, mirrored for the front camera) feeds analysis and the live look.
- Zoom uses Camera-app units (`displayVideoZoomFactorMultiplier`); preset buttons come from the lens switch-over points.
- Also handles focus and exposure point, exposure bias, custom ISO and shutter, locked lens position, white-balance gains and torch.
- Handles interruptions and runtime errors.
- `readings()` returns ISO, shutter, lens position, Kelvin and `exposureTargetOffset` (the meter). They're polled every 0.25 s while the camera runs.
- Every capture setting is checked against what the output says it supports, because AVFoundation throws Objective-C exceptions on invalid settings.

### Scan flow (the ✦ button), modeled on the owner's screen recording of Framed

1. **✦** → `LiveCameraModel.startAutoScan()`. The phase becomes `.finding` ("Finding your shot…" in yellow), the button turns to ✕, and live analysis runs about 5 times a second.
2. After about 4 steady framing plans → `.framing`. If the plan needs a zoom change, the camera zooms itself ("Framing your shot…"); otherwise it says "Centered — framing up…".
3. After about 0.9 s:
   - `ShotDirector` runs `VNClassifyImageRequest` on the subject's box and on the whole scene. That produces the green tag ("flower · bedroom").
   - It measures subject-versus-background brightness and builds a one-line instruction from templates.
   - On iOS 26 with Apple Intelligence, `FoundationModels` rewords the line, with a 2.5 s timeout and a cleanup step.
   - Phase becomes `.guiding`: the instruction shows in green and the button becomes ↻.
4. While guiding: a target cross (it turns green when lined up), a green tag that follows the subject, a haptic when framed, and "Framed — take the shot".
5. Long exposures (0.1 s or longer) show "Hold still · 1″" with a progress bar.
6. After capture:
   - The project is saved, with the DNG as the original when RAW is on.
   - `AutoEdit.suggest` sets the look to Clean (unless the user picked one), corrects exposure only when brightness is outside 0.34–0.52, lifts shadows and recovers highlights when needed, and adds vibrance 0.1 and grain 0.12.
   - The editor then opens.

### FramingCoach (pure and tested)

- **Subject plans:** zoom factors 0.75 to 2, with the subject on thirds or the center.
- **Person plans:** built from Vision body pose. Head & shoulders, waist up, knees up and full body, with the eye line on the upper third. Frame edges are penalized near joints (neck, elbows, wrists, hips, knees, ankles).
- **Landscape plans:** the horizon on the upper third when the sky is plain, the lower third when it's textured. The horizon height comes from a row brightness and texture profile.
- **Look direction:** `SceneAnalyzer.facing` compares the nose position with the eye midpoint; space is left in front of the face.
- **Steadiness:** `stabilized()` keeps the same idea (same shot type, same third) unless the best alternative scores 0.08 higher, and it eases changes.
- **`advice()`** returns the on-screen target (adjusted for any zoom), the zoom to use (or "Step back" / "Step closer"), and hints.
  - "Pan left" means the subject has to move right in the picture; "Tilt up" means it has to move down.
  - The front camera shows "Line up with the ring" instead of directions.

### Looks (original names)

- Daylight Neg — natural color negative
- Ember 200 — warm negative
- Cold Chrome — cool slide film
- Soft Bloom — soft portrait tones
- Push 1600 — fast film, pushed, grainy
- Silver Tone — neutral black and white
- Sun Faded — faded print
- Paper Sepia — vintage paper
- Deep Print — rich contrast
- Quiet Cinema — muted cinematic color
- Golden Split — warm highlights, cool shadows
- Clean — clean, neutral starting point

Each look is a tone curve plus white balance, saturation and vibrance, split toning (kernel), glow and clarity, and its own grain and halation, all scaled by Strength.

### Editor

- **Tabs:** Looks / Adjust / Effects / Frames, with a yellow dot when a tab is changed and a yellow Reset.
- **Looks:** a strip rendered from the photo. Tap the selected look to show its Strength ruler.
- **Adjust:** Exposure, Contrast, Highlights, Shadows, Whites, Blacks, Fade, Warmth, Tint, Saturation, Vibrance. HSL, Grading, Curves, Calibration and Crop open in sheets.
- **Effects:** Grain (Size), Motion (Angle), Light leak (Size, Warmth, Shuffle, drag on the photo to place it), Scratches (Shuffle), Halation (Spread), Dust (Shuffle), Glow, Fringe (chromatic aberration), Vignette.
- **Frames:** None, Plain, White, Paper, Black, Negative, Specs, and a date stamp (only when EXIF has a capture date).
- **Bottom bar:** Delete (asks first) · undo · redo · Save. Save exports full resolution to Photos and returns to the camera.
- **Undo:** a burst of changes within 0.6 s counts as one undo step. Edits autosave to the project after 1 s.

### Other features

- **Exposure strip:** `AUTO | shutter | ISO | meter`. Tap shutter or ISO to show a `TickRuler` of third stops limited to the device's range. Going manual on one keeps the other at its current value.
- **CUSTOM mode:** draw a frame, move it, resize it from the corners, or pick a ratio. Tap a subject to track it with `VNTrackObjectRequest`, and it shows when the subject is aligned.
- **⠿ panel:**
  - CAMERA: Flash, Timer, Aspect, Exposure, Grid, Level, Format (HEIF/JPEG), Torch
  - PRO: Scan, Custom, Manual (ISO, shutter, focus, white balance; rows disabled when unsupported), RAW (Off → RAW → ProRAW, only what's supported)
- **Library:** reached from the thumbnail. Import from Photos (originals copied byte-for-byte), open, duplicate an edit, delete with confirmation. Projects whose original is missing stay listed so they can be deleted.

## Tests (`FrameCraftTests/FeatureTests.swift`)

They cover:

- composition geometry and aspect-fill mapping
- capture-aspect crops and zoom presets
- frame merging and the coach: look direction, joints, horizon detection and placement, advice directions, zoom and step back, front camera, steadiness
- renderer: kernels are present, no-op identity, curves, tolerant decoding, calibration, deterministic damage, distinct looks, look strength, every slider changes the render, geometry
- project store: keeps originals, missing originals
- EXIF metadata read but never invented
- frame sizes, carried-over metadata and location removal, every export format
- undo/redo and one-drag-one-undo
- auto edit, instruction templates and model-output cleanup, exposure stops, effect options

**All of them pass on CI at `5c6168e`.**

## Known limits and things to verify on a real iPhone

- **Nothing has been tried on a device yet.** That includes the camera, scan behavior, pan and tilt directions, auto zoom, face direction, live look frame rate, RAW and ProRAW, manual controls, flash and torch, and hold-still.
- **Horizon tilt:** the sign of Vision's horizon angle was reasoned from the documentation, not tested. Negate it in `SceneAnalyzer.analyze` if the hint points the wrong way.
- **Subject names and instructions** are generated on the phone (Vision's classifier labels can be generic). They won't match Framed's wording, which likely comes from a cloud vision model.
- **Manual exposure on virtual multi-lens devices** may be reported as unsupported; the UI then disables it.
- **The "Paper" frame texture and the dust and scratch patterns** are procedural and seeded, so the same photo always looks the same.
- **Calibration** is an approximation (it rotates and scales each primary color), not a real camera profile.

## Gotchas learned

- The Swift compiler times out on long mixed-type arithmetic in one expression. Split it into typed `let`s (this happened with luminance sums).
- iOS can't compile Metal source at runtime. Kernels must be `[[stitchable]]` functions in a `.metal` file, compiled at build time (`MTLLINKER_FLAGS = -framework CoreImage` is set), and loaded with `CIColorKernel(functionName:fromMetalLibraryData:)`.
- Core Image's addition blend also adds alpha. Use separate color matrices with only one image's alpha set to 1 (see `fringe`), or a kernel.
- `CIRandomGenerator`'s alpha is random, and the image tiles every 256 px.
- `@Observable` classes in this project avoid `didSet` on observed properties; use explicit setter methods instead.
- When editing Swift files from a Windows shell, long shell here-documents containing quotes broke several times. Write a patch script to a file and run it instead.

## Ideas not built yet (from conversations)

- **Taking photos:** a live composition score, more grids (golden spiral, diagonals), symmetry and leading-line detection, auto-level on capture, burst with best-shot pick, Camera Control button support, Lock Screen launch.
- **Camera tools:** live histogram, focus peaking, zebras, portrait depth blur, night mode stacking, Live Photos.
- **Editing:** saving your own looks, copy/paste edits, batch export, LUT import, a before/after split view, subject and sky masks, a healing brush.
- **Library and learning:** albums and favorites, Instagram export sizes, "why this frame?" explanations, composition challenges.
