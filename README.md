# PinTop 0.4.3

PinTop is a small macOS menu-bar utility that keeps a window you care about visible. Focus a normal app window and press **Command + Option + T** to pin it; press the shortcut again while the same window is focused, or choose **Unpin Window** from the menu-bar icon, to stop.

PinTop is built by **CognitiveDiscovery LLC**.

PinTop intentionally manages **one pinned window at a time**. Pinning a different window replaces the existing pin. The menu command acts on the last external application’s currently focused window; the global shortcut is the least ambiguous way to select a window.

## Two pin modes

Choose a mode from **Pin Mode** in the menu bar. The choice is remembered and applies to the next pin.

- **Raise real window (clickable)** — the default and original behavior. PinTop asks macOS to raise the real window using the public Accessibility `AXRaise` action, reacting to application activation and Accessibility window events with a one-second fallback. The window stays fully interactive, but because no public API can set a true always-on-top level on another app's window, a focused foreground window can cover it until you switch apps. Needs only Accessibility permission.

- **Live video mirror (stays on top)** — shows a continuously updating video copy of the chosen window in a floating panel that PinTop owns. Because the panel belongs to PinTop, it genuinely stays above other applications, and the original window keeps keyboard focus — you can keep typing in it while the mirror floats on top. The mirror opens at the source window's size, on top of it but offset so a strip of the original stays visible (click that strip to refocus the real window). It is **view-only** (you interact with the real window, not the copy), draggable and resizable, and uses Apple's public **ScreenCaptureKit**. It needs **Screen Recording** permission and requires **macOS 13 or later**.

Which to use: pick **raise** when you want the real, clickable window and can tolerate it being covered while you work elsewhere; pick **live mirror** when you want the window to stay visibly on top while you type in another window (for example, watching a video or keeping reference material visible while working).

## Important limitations

macOS does not provide a public API that lets one app assign an always-on-top level to another app's window, so PinTop offers the two modes above instead of a true cross-application window level. Each has trade-offs.

Raise mode:

- Another window can cover the pinned window; if an application does not emit a useful event, the fallback correction can take about one second, and a window you have actively focused stays on top until you switch apps.
- Some applications or window types do not support `AXRaise`.
- Full-screen Spaces, Mission Control, sheets, popovers, games, and protected apps may not cooperate. PinTop checks the initial raise result and will not claim a window is pinned when the action fails.

Live-mirror mode:

- The floating panel is a **view-only** copy; you cannot click or type into the mirrored content.
- It requires Screen Recording permission and macOS 13 or later.
- The real window keeps focus and stays where it is; the mirror is an additional floating copy on top.

## Requirements

- macOS 12 or later (raise mode); macOS 13 or later for the live-mirror mode
- Xcode Command Line Tools (`xcode-select --install`)

## Build and install

In Terminal:

```bash
cd PinTop
./build.sh
cp -R build/PinTop.app /Applications/
open /Applications/PinTop.app
```

Installing the app in its final location before granting Accessibility permission reduces avoidable permission churn.

The default build is for the Mac that runs the script. Optional build settings:

```bash
# Use a stable Apple code-signing identity when one is installed:
SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" ./build.sh

# Override the bundle identifier (default: com.cognitivediscovery.pintop):
BUNDLE_IDENTIFIER="com.yourdomain.pintop" ./build.sh

# Override the detected architecture or minimum supported macOS version:
ARCH=arm64 MACOSX_DEPLOYMENT_TARGET=13.0 ./build.sh

# Skip signing entirely (not recommended):
SIGNING_IDENTITY=none ./build.sh
```

The default ad-hoc signature is suitable for local testing, but rebuilding changes its identity. macOS may therefore require Accessibility permission again after a rebuild. The script deliberately does not use `codesign --deep`; this app contains no nested code.

## Distribute (Developer ID + notarization)

To distribute PinTop outside the Mac App Store, sign it with a **Developer ID Application** certificate and have Apple notarize it; users can then download and launch it without Gatekeeper blocks. Note that PinTop's raise mode cannot ship in the Mac App Store: the store requires the App Sandbox, and sandboxed apps cannot be granted the Accessibility permission raise mode depends on. Developer ID distribution has no such restriction.

One-time setup (requires an Apple Developer Program membership):

1. Create a **Developer ID Application** certificate in Xcode (Settings → Accounts → Manage Certificates) or at developer.apple.com, and make sure it is in your login keychain (`security find-identity -v -p codesigning` should list it).
2. Create an **app-specific password** for your Apple ID at account.apple.com (Sign-In and Security → App-Specific Passwords).
3. Store the notarization credentials once (the team ID is the 10-character code in parentheses in your certificate name):

   ```bash
   xcrun notarytool store-credentials pintop-notary \
     --apple-id your-apple-id@example.com \
     --team-id TEAMID \
     --password <app-specific-password>
   ```

Then every release is one command:

```bash
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARIZE=1 ./build.sh
```

This signs with the hardened runtime and a secure timestamp, submits the app to Apple's notarization service (typically a few minutes), staples the resulting ticket into the app, verifies the result with Gatekeeper, and leaves a ready-to-distribute `build/PinTop.zip`. Use a different credentials profile name with `NOTARY_PROFILE=<name>`.

## First run and Accessibility permission

1. Launch PinTop.
2. macOS should request Accessibility access.
3. Open **System Settings → Privacy & Security → Accessibility** and enable PinTop.
4. Use the menu-bar pin icon to confirm that permission says **Granted**.
5. If macOS does not recognize the new setting immediately, quit and reopen PinTop.

Accessibility is a broad macOS permission. This source uses it only to identify the focused application/window, read an optional window title, inspect supported actions, perform `AXRaise`, and observe selected-window lifecycle, title, and common focus/order events. PinTop has no networking code and does not write user data.

## Screen Recording permission (live-mirror mode only)

The live-mirror mode captures a video copy of the window you pin, so macOS requires **Screen Recording** permission for it. Raise mode does not use it.

1. Select **Pin Mode → Live video mirror** from the menu bar.
2. Pin a window. macOS will request Screen Recording access the first time.
3. Open **System Settings → Privacy & Security → Screen Recording** and enable PinTop (the menu’s **Open Screen Recording Settings…** item links there).
4. macOS usually requires the app to relaunch after this permission is granted; quit and reopen PinTop, then pin again.

PinTop captures only the single window you choose, only while it is mirrored, and stops capture when you unpin. It uses Apple’s public ScreenCaptureKit; it does not record to disk or send anything over the network.

## Use

1. Optionally choose **Pin Mode → Raise real window** (default) or **Live video mirror** from the menu bar.
2. Click the window to pin.
3. Press **Command + Option + T**.
4. A filled pin icon means PinTop accepted the window — in raise mode its first raise request succeeded; in mirror mode the floating video panel is showing.
5. Focus the same window and press **Command + Option + T** again to unpin it (in mirror mode, pressing the shortcut clears the mirror).
6. The menu-bar icon also provides **Unpin Window**, status details, the current **Pin Mode**, and links to the Accessibility and (in mirror mode) Screen Recording settings. PinTop clears the selection when macOS reports that the selected window was destroyed, when the owning app exits, when the Accessibility element becomes invalid, or — in mirror mode — when the capture stream ends.

A warning icon and alert sound mean the operation failed; open the menu to read the status.

## Change the shortcut

Edit the single `pinShortcut` declaration near the top of `Sources/main.swift`:

```swift
private let pinShortcut = Shortcut(
    keyCode: UInt32(kVK_ANSI_T),
    keyLabel: "T",
    modifiers: UInt32(cmdKey | optionKey),
    signature: "PINT".fourCharCodeValue,
    identifier: 1
)
```

Keep `keyCode` and `keyLabel` consistent. The displayed shortcut is generated from this declaration, so menu and error text cannot silently drift apart.

## What changed from 0.1

- Uses one deterministic pinned window instead of competing pinned windows.
- Uses Accessibility-element equality rather than mutable titles as identity.
- Checks supported actions and the result of the first raise request.
- Does not treat a missing title as proof that a window closed.
- Moves repeated cross-process Accessibility calls off the main thread.
- Runs a slower fallback raise timer only while a window is pinned and reacts immediately to common window-order events.
- Applies a short messaging timeout to both the app and selected window elements.
- Detects selected-window destruction when supported, application termination, and invalid window elements.
- Tracks the last external app so the menu command does not accidentally select PinTop.
- Removes deprecated notification APIs.
- Centralizes shortcut display and behavior.
- Enforces the macOS deployment target during compilation.
- Removes unnecessary `codesign --deep` signing.

## Version 0.4.3 changes

- Replaces the static attribution line in the menu with an **About PinTop** item that opens the standard About panel (icon, version, CognitiveDiscovery LLC copyright).

## Version 0.4.2 changes

- The mirror panel opens at the same size as the source window, overlapping it with a diagonal offset so a strip of the original stays visible and clickable; the panel is clamped to the screen. Previously it opened at half size, centered.

## Version 0.4.1 changes

- Fixes a live-mirror race where a mirror still starting could be orphaned by a second pin made before the first finished, leaving an always-on-top panel (with a live capture stream) that only quitting could remove. A superseded start is now torn down instead of adopted.
- Selects the mirrored window by matching the focused window's Accessibility title, so multi-window apps mirror the window the user actually chose; the frontmost-window heuristic remains the fallback.
- Starts capture directly from the window resolved at pin time (one shareable-content enumeration instead of two).
- Adds Developer ID distribution support to `build.sh`: hardened-runtime signing plus `NOTARIZE=1` for Apple notarization, ticket stapling, and Gatekeeper verification.
- Adds a menu attribution line and changes the default bundle identifier to `com.cognitivediscovery.pintop`. PinTop is built by CognitiveDiscovery LLC.

## Version 0.4.0 changes

- Adds a **live video mirror** pin mode (macOS 13+) that floats a view-only, draggable, resizable copy of the chosen window on top of everything using Apple’s public ScreenCaptureKit. The original window keeps keyboard focus, so you can keep typing in it while the mirror stays visible — the one behavior raise mode cannot provide with public APIs.
- Adds a **Pin Mode** menu to switch between raise and live-mirror modes; the selection persists across launches.
- Requests and surfaces **Screen Recording** permission for the mirror mode, with a menu shortcut to its settings pane.
- Clears the mirror automatically when the source window or app goes away.
- Continues to use public APIs only; no private window-level or window-id symbols are introduced.

## Version 0.3.1 changes

- Collapses a burst of triggers into at most one in-flight raise and one in-flight title read, so returning to the pinned app or using a title-churning app no longer issues redundant cross-process Accessibility calls.
- No longer observes `kAXWindowCreatedNotification`. PinTop will not raise the pinned window over the same app’s new modal dialogs, save panels, or Preferences windows; a new window that takes focus is still handled by the focused-/main-window-changed events, and the one-second fallback covers the rest.
- Stores the last external application as an `NSRunningApplication`, matching how the pinned window’s identity is already tracked.

## Version 0.3.0 review fixes

- Replaces the unconditional four-times-per-second loop with event-driven raises plus a one-second fallback.
- Moves live title refreshes off AppKit’s main thread and serializes them with repeated raise calls.
- Observes supported title, focused-window, main-window, and window-created notifications.
- Stores the original `NSRunningApplication` object for termination identity rather than probing a reusable PID with `kill(pid, 0)`.
- Keeps destruction observation on the selected window itself and retains invalid-element and application-termination fallbacks.
- Continues to use public APIs only; private `SLS`/underscored Accessibility symbols are intentionally excluded.
