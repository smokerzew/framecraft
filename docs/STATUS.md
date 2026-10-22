# FrameCraft status

| Level | Meaning |
|---|---|
| SOURCE IMPLEMENTED | The code is written. |
| CI BUILD PASSED | It compiles with Xcode 26 on GitHub's macOS runner. |
| IPA PACKAGE VERIFIED | CI found `Payload/FrameCraft.app` with its binary and Metal kernels inside the `.ipa`. |
| SIDELOAD INSTALL VERIFIED | Installed on a real iPhone with Sideloadly. |
| PHYSICAL CAMERA VERIFIED | Tried with the real camera. |
| RAW CAPTURE VERIFIED | A RAW or ProRAW photo was taken and edited on a real iPhone. |

**Current state:** source implemented, and the first CI run is in progress. Nothing has been installed or tried on an iPhone yet; the Simulator has no camera.

## Known limits (documented, not hidden)

- **Horizon direction:** the sign of Vision's horizon angle comes from the documentation, not a device test. If "turn counterclockwise" points the wrong way, negate it in `Composition/SceneAnalyzer.swift`.
- **Manual controls on multi-lens iPhones:** some iPhones don't allow custom exposure on the combined virtual camera. In that case the row shows N/A instead of doing nothing.
- **Live look preview:** it renders on the GPU at 2× scale, but its frame rate on older iPhones is unmeasured.
- **RAW editing:** the DNG is the original. Its preview and export use iOS's standard RAW decoding, with no separate RAW development controls.
- **Tracking:** it only guides you. The camera never moves on its own.
- **Calibration:** an approximation (it moves the hue and saturation of each primary), not a camera-profile editor.
