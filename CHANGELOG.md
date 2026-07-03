# Changelog

## 0.5.1

- Wires in the live Lemon Squeezy store (423819) and PinTop product (1194312): license
  activation now rejects a key issued for any other product, and the website's Buy button
  points at the real $3.99 checkout.

## 0.5.0

- Adds a **7-day free trial and one-time $3.99 license**. The menu shows the trial state
  ("Free trial: N days left"), a **Buy PinTop ($3.99)…** item that opens the purchase page,
  and an **Enter License Key…** dialog. After the trial ends, creating new pins is disabled
  until a key is entered; unpinning and the rest of the menu keep working.
- License keys are sold through Lemon Squeezy (merchant of record). Activation is the only
  network request PinTop ever makes: one HTTPS call to the Lemon Squeezy license API when a
  key is entered, verified against PinTop's store/product and then stored locally forever.
- The trial start date is stored in preferences and in an Application Support marker file
  (the earliest wins). This is an honesty gate, not DRM.
- Adds the CognitiveDiscovery LLC website under `site/` (static, self-contained): a company
  homepage plus the PinTop product page, served via Cloudflare Pages' free tier at
  `pintop.cognitivediscovery.com` (and also `cognitivediscovery.com/pintop/`).

## 0.4.3

- Replaces the static attribution line in the menu with an **About PinTop** item that opens
  the standard macOS About panel (app icon, version and build, CognitiveDiscovery LLC
  copyright).

## 0.4.2

- The mirror panel now opens at the **same size as the source window**, on top of it but
  shifted diagonally (about 100 points) so a strip of the original stays visible — click that
  strip to refocus the real window. The shift direction adapts to available screen space and
  the panel is clamped to the screen. Previously the mirror opened at half size, centered.

## 0.4.1

- Fixes a race in live-mirror mode: a mirror whose capture was still starting could be
  orphaned by a second pin (mirror or raise) made before the first finished — leaving a
  floating always-on-top panel with a live capture stream that only quitting could remove.
  A start that is superseded or invalidated is now torn down instead of adopted.
- Mirrors the window the user actually focused: the ScreenCaptureKit window is now selected
  by matching the focused window's Accessibility title first, so multi-window apps (floating
  panels, picture-in-picture) mirror the right window. The frontmost-window heuristic remains
  the fallback.
- Starts capture directly from the window resolved at pin time instead of re-enumerating all
  shareable content a second time, removing a wasted cross-process enumeration and a spurious
  "window unavailable" failure mode.
- Adds distribution support to `build.sh`: real signing identities now get the hardened
  runtime and a secure timestamp, and `NOTARIZE=1` zips, submits to Apple notarization,
  staples the ticket, and verifies the result with Gatekeeper.
- Changes the default bundle identifier to `com.cognitivediscovery.pintop`.
- Adds a version/attribution line to the menu; PinTop is built by CognitiveDiscovery LLC.
- Fixes the remaining compiler warning so release builds are warning-free.

## 0.4.0

- Adds a second pin mode, **Live video mirror**, alongside the original raise mode. The mirror shows a continuously updating video copy of the chosen window in a floating, draggable, resizable panel that PinTop owns. Because the panel belongs to PinTop, it genuinely stays on top of other applications, and the real window keeps keyboard focus — you can keep typing in it while the mirror floats above. The mirror is view-only.
- Adds a **Pin Mode** submenu to the menu bar to switch between "Raise real window (clickable)" and "Live video mirror (stays on top)". The choice is remembered across launches and applies to the next pin.
- The live mirror uses Apple's public **ScreenCaptureKit** and requires **Screen Recording** permission; the menu surfaces that permission and a shortcut to its settings pane when mirror mode is selected. Mirror mode requires macOS 13 or later; on macOS 12 it is disabled and raise mode remains available.
- Clears the live mirror automatically when the source window or its app goes away (ScreenCaptureKit reports the stream stopping).
- Still uses public APIs only — no private window-level or window-id symbols. The mirror is the only public-API way to keep a window visibly on top while the window behind it keeps focus.

## 0.3.1

- Coalesces immediate-raise requests: a burst of triggers (app activation plus focused-/main-window changes that can fire for one logical event) now results in at most one queued `AXRaise` instead of several.
- Coalesces pinned-window title reads for the current pin, so a title-churning app (a terminal running a long command, a busy browser) produces at most one in-flight cross-process read per burst.
- Stops raising the pinned window over the same app’s newly created windows: `kAXWindowCreatedNotification` is no longer observed, so modal dialogs, save panels, and Preferences windows stay usable. A new window that takes focus still triggers a corrective raise via the focused-/main-window-changed events, and the one-second fallback covers the rest.
- Stores the last external application as `NSRunningApplication` for identity consistency with the pinned window, replacing the raw `pid_t`.

## 0.3.0

- Reacts immediately to application activation and supported Accessibility window events.
- Slows the periodic safety raise from 250 milliseconds to one second.
- Refreshes changing window titles asynchronously on the serialized Accessibility queue.
- Observes selected-window title changes and common same-app focus/order changes.
- Uses the original `NSRunningApplication` instance for termination identity and removes the reusable-PID liveness probe.
- Documents the menu command’s last-external-app behavior and the decision not to use private APIs.

## 0.2.1

- Starts the periodic raise timer only after a window has actually been pinned.
- Adds an Accessibility observer for selected-window destruction when the target app supports that notification.
- Cleans up the observer when replacing a pin, unpinning, or quitting.
- Clarifies the Accessibility purpose string and documentation.

## 0.2.0

- Uses one deterministic pinned window instead of competing pinned windows.
- Uses Accessibility-element equality rather than mutable titles as identity.
- Checks supported actions and the result of the first raise request.
- Does not treat a missing title as proof that a window closed.
- Moves repeated cross-process Accessibility calls off the main thread.
- Applies a short messaging timeout to the app and selected window.
- Detects application termination and invalid window elements.
- Tracks the last external app so the menu command does not accidentally select PinTop.
- Removes deprecated notification APIs.
- Centralizes shortcut display and behavior.
- Enforces the macOS deployment target during compilation.
- Removes unnecessary recursive signing.
