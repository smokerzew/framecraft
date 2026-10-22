# FrameCraft

A native iPhone camera for composed, film-look photos, built with SwiftUI, AVFoundation, Vision and Core Image. Its interface comes from Camera Glass Pro's Liquid Glass camera design.

FrameCraft is a separate app with its own bundle ID (`com.smokerzew.FrameCraft`), so it installs next to Camera Glass Pro rather than replacing it.

## What it does

- **Camera:**
  - Live preview, with front and back cameras.
  - Lens-aware zoom (.5 only if the iPhone has an ultra-wide lens).
  - Tap to focus and expose; hold to lock focus and exposure.
  - Exposure compensation, flash, torch and a self-timer.
  - Capture at full resolution in HEIF or JPEG, plus RAW or Apple ProRAW where the iPhone supports it.
  - Manual ISO, shutter speed, focus and white balance, where supported.
  - Capture framing of 3:4, 4:5, 9:16 or 1:1, which becomes the photo's real (re-editable) crop.
- **AUTO FRAME:** analyzes the live scene with Vision (faces, people, salient objects, horizon) and checks exposure clipping. It then suggests a framing, with an alternative.
  - Notes are labeled **measured** (ruler) or **suggestion** (bulb).
  - **Apply** makes the suggestion the next photo's crop. You can also rescan or dismiss it.
- **CUSTOM:** draw your own frame (Free, 3:4, 4:5, 1:1 or 9:16), then move and resize it. Tap a subject and FrameCraft tracks it, showing when it lines up with a third or the center.
- **Film looks:** twelve original looks, previewed live on the viewfinder and adjustable afterwards:
  - Daylight Neg, Ember 200, Cold Chrome, Soft Bloom, Push 1600, Silver Tone
  - Sun Faded, Paper Sepia, Deep Print, Quiet Cinema, Golden Split, Clean
- **Editor (non-destructive):**
  - Look and strength.
  - Exposure, contrast, highlights, shadows, whites, blacks, fade, temperature and tint.
  - Saturation, vibrance, HSL (8 colors), color grading, RGB/R/G/B curves and calibration.
  - Grain, halation, glow, light leak, dust, scratches, motion blur and vignette.
  - Crop, rotate and straighten.
  - Hold the photo to compare before and after. Undo, redo, and per-section reset.
- **Library:** captures and imported photos. The original is kept byte-for-byte and the edit is saved as data. You can reopen, duplicate an edit, or delete (with a confirmation).
- **Export:**
  - Full resolution in JPEG, HEIF or PNG.
  - Frames: Plain, White, Paper, Black, Negative and Specs. The Specs frame shows real EXIF values only.
  - Date stamp, from the capture date only.
  - Capture metadata is kept, with an option to remove location.
  - Save to Photos or share.

See [docs/STATUS.md](docs/STATUS.md) for how far each feature has been checked.

## Building (no Mac needed)

GitHub Actions does the build on a macOS runner (`.github/workflows/build-ios-ipa.yml`):

1. Generates the Xcode project from `project.yml` with XcodeGen.
2. Runs the unit tests in the iPhone Simulator.
3. Builds an unsigned Release app.
4. Packages and checks `FrameCraft.ipa`.
5. Publishes the IPA to the `latest` release.

Download it here:

`https://github.com/smokerzew/framecraft/releases/download/latest/FrameCraft.ipa`

Install it with Sideloadly using your own Apple ID; see [docs/SIDELOADLY_INSTALL.md](docs/SIDELOADLY_INSTALL.md).
