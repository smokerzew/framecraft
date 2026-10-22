# Installing FrameCraft with Sideloadly (Windows)

FrameCraft is built by GitHub Actions as an **unsigned** `.ipa`. Sideloadly signs it with your own Apple ID and installs it on your iPhone. You never need a Mac.

1. **Download the IPA:** `https://github.com/smokerzew/framecraft/releases/download/latest/FrameCraft.ipa`. No sign-in is needed. Saving it into this folder's `dist\` is a good habit.
2. **Install Sideloadly** from its official website, sideloadly.io.
3. **Install what Sideloadly needs on Windows.** Follow its instructions: the non-Microsoft-Store iTunes and iCloud for Windows. You already set these up for Camera Glass Pro, including the Apple Root CA.
4. **Connect the iPhone** with a USB cable and unlock it.
5. **Tap Trust** on the iPhone if it asks whether to trust this computer.
6. **Open Sideloadly.** Your iPhone should appear in the device list.
7. **Drag `FrameCraft.ipa`** onto Sideloadly, or click the IPA button and choose it.
8. **Type your Apple ID into Sideloadly** and click **Start**. Enter your password and code only in Sideloadly or Apple's own prompts, never in a chat.
9. **First launch on the iPhone:**
   - If iOS says the developer isn't trusted, go to Settings › General › VPN & Device Management, tap your Apple ID, then tap **Trust**.
   - On iOS 16 or later you may also need Settings › Privacy & Security › **Developer Mode** turned on, which restarts the phone.
10. **Open FrameCraft** and allow camera access.

FrameCraft has its own bundle ID, so it installs next to Camera Glass Pro instead of replacing it.

## Things to know

- With a free Apple ID, sideloaded apps expire after **7 days**. Run Sideloadly again to re-sign; your library stays as long as you don't delete the app. A free account can also only have a few sideloaded apps at once.
- FrameCraft asks for no special entitlements (no iCloud, push notifications or app groups), so a free account can sign it.
- **If Sideloadly shows an error,** read its exact message:
  - **"Maximum number of apps"** means you're at the free-account limit. Remove an older sideloaded app.
  - **"Your session has expired" or a login error** means you should sign in again in Sideloadly.
  - **An entitlement or provisioning error** shouldn't happen with this app. If it does, copy the full message so it can be looked at.

## What to test on the iPhone

- Camera permission prompt, then the live preview; switch between front and back cameras.
- Taking photos at 3:4, 4:5, 9:16 and 1:1. Each opens in the editor, cropped to that ratio.
- Zoom buttons and pinch (.5 should appear only on iPhones with an ultra-wide lens), tap to focus, the EV slider, flash, torch and timer.
- **AUTO FRAME:** do the suggestions follow the scene? Does **Apply** crop the next photo to the suggested frame?
- **CUSTOM:** draw a frame, tap a subject, then move the phone until it says ALIGNED.
- MANUAL (ISO, shutter, focus, WB) and RAW/ProRAW, which only appear on iPhones that support them.
- The editor: looks, sliders, HSL, curves, undo and redo, and holding the photo to see the original.
- Export with each frame and the date stamp, Save to Photos, and Share.
