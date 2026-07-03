# PinTop manual test checklist

Run these checks on macOS after building with `./build.sh`.

## Build and launch

- `plutil -lint build/PinTop.app/Contents/Info.plist` succeeds.
- `codesign --verify --strict build/PinTop.app` succeeds unless signing was explicitly disabled.
- PinTop launches as a menu-bar utility without a Dock icon.
- The global shortcut is shown as **Command + Option + T**.

## Permission handling

- With Accessibility permission disabled, PinTop requests permission and does not report a successful pin.
- After permission is enabled, the shortcut works; relaunch only if macOS does not refresh the permission immediately.
- Removing permission while a window is pinned clears or disables the pin rather than reporting continued success.

## Window behavior (raise mode)

These checks assume **Pin Mode → Raise real window** (the default).

- Focus a normal window, press the shortcut, and confirm the menu shows that exact app/window.
- Change the window title, then focus it and press the shortcut again; it unpins instead of creating a second identity.
- Pin a different window; it replaces the old selection.
- Close the selected window; the pin clears through the destruction notification or the next invalid-element check.
- Quit the selected window’s owning app; the pin clears.
- Switch to another application; the selected window is re-raised promptly from the activation event.
- In the selected window’s own application, focus a different existing window; supported apps trigger an immediate corrective raise that brings the pinned window back to front.
- In the selected window’s own application, open a new window that takes focus (for example a new document); the pinned window returns to front via the focused-/main-window-changed events.
- In an app that does not emit the relevant Accessibility event, confirm the one-second fallback still restores the selected window.
- Use a window that does not support `AXRaise`; PinTop reports failure and does not mark it pinned.

## Same-app dialogs and new windows

- With a window pinned, trigger a **modal dialog** in that same application (for example an unsaved-changes sheet or alert). The dialog stays in front and remains usable; PinTop does not raise the pinned window over it.
- With a window pinned, open the same application’s **Preferences/Settings** window. It stays usable and is not hidden behind the pinned window.
- With a window pinned, invoke a **save panel / open panel** in that same application. The panel stays in front and accepts input.
- After dismissing the dialog/panel above, bring another *application* forward; the pinned window still returns to front. This confirms removing window-created observation did not break cross-application raising.

## Coalescing under event churn

- Rapidly switch between the pinned application and another app several times (Command+Tab back and forth). The pinned window still pops back to front promptly on each switch, and bursts of activation plus focus/main-window events collapse into a single raise rather than several redundant `AXRaise` calls.
- Pin a window in a **title-churning app** (a terminal running a command that updates its title continuously, or a browser switching tabs/loading pages). The menu title updates without lag, and rapid title changes collapse into at most one in-flight cross-process read per burst rather than one read per change.

## Shortcut and menu behavior

- Invoke the command from the menu-bar icon after another app was frontmost; PinTop targets that app’s currently focused window, not PinTop itself.
- Change a pinned window’s title and open the PinTop menu while the target app is busy; the menu stays responsive and updates the title asynchronously when available.
- Run a second application that already owns **Command + Option + T**; PinTop reports that the shortcut is unavailable while leaving the menu command usable.

## Pin mode selection

- Open the menu and confirm **Pin Mode** has two options with a checkmark on the current one: "Raise real window (clickable)" and "Live video mirror (stays on top)". The default is raise.
- Switch the mode, quit, relaunch; the previously selected mode is still checked (persisted).
- On macOS 12, the live-mirror option is disabled with a "needs macOS 13 or later" note, and raise mode still works.

## Live video mirror mode

Select **Pin Mode → Live video mirror** first. (Requires macOS 13+.)

- With Screen Recording permission not yet granted, pin a window: PinTop requests Screen Recording permission and reports that it is required if denied. The menu shows "Open Screen Recording Settings…".
- After granting Screen Recording (relaunch if macOS requires it), focus a normal window and press the shortcut: a floating panel appears showing a live copy of that window, and the menu shows "Mirroring: App: Window".
- The mirror opens at the same size as the source window, overlapping it but shifted diagonally so a strip of the original remains visible; clicking that strip focuses the real window. For a window near the screen's right/bottom edge, the shift flips direction instead of going off screen; the panel never opens outside the visible screen area.
- **The key behavior:** click the window behind the mirror and type in it. The back window keeps keyboard focus and receives your typing, while the mirror panel stays on top and updates live to show what you type. The mirror never steals focus.
- Drag the mirror panel by its body to reposition it; drag an edge/corner to resize it. The video keeps its aspect ratio.
- Bring various other applications forward; the mirror panel stays visible above them.
- Press the shortcut again (or choose **Unpin Window**): the mirror panel disappears and capture stops.
- Close the source window (or quit its app) while mirroring: the mirror clears itself and the menu returns to "No window pinned".
- Switch from mirror mode back to raise mode while a mirror is active, then pin a new window: only one thing is ever pinned at a time (the mirror is torn down).
- Confirm the menu-bar icon shows the filled pin while a mirror is active and the empty pin after unpinning.
- In an app with several windows (for example a browser with a picture-in-picture window or an editor with a floating palette), focus a specific window and pin it: the mirror shows that window, not another window of the same app.
- While "Starting live mirror…" is still in progress (pin a large window of a busy app), immediately pin a different window: exactly one mirror panel appears, for the most recent request. No second panel is left floating, and unpinning removes everything.
- Choose **About PinTop** from the menu: the standard About panel opens in front of other apps, showing the PinTop icon, the version and build from Info.plist, and the CognitiveDiscovery LLC copyright.

## Trial and license

- On a fresh machine (or after `defaults delete com.cognitivediscovery.pintop` and removing `~/Library/Application Support/PinTop/`), the menu shows "Free trial: 7 days left" plus **Buy PinTop ($3.99)…** and **Enter License Key…**.
- Deleting only the preferences does not reset the trial (the Application Support marker restores the earlier date), and vice versa.
- **Buy PinTop ($3.99)…** opens the purchase page in the default browser.
- With the trial expired, pressing the shortcut on an unpinned window reports that the trial ended and does not pin; **Unpin Window** and unpinning via the shortcut still work for an existing pin.
- Entering an empty or invalid key shows a clear error; entering a valid key shows "License activated", the menu switches to "License: Active", and the purchase items disappear.
- After activation, quit and relaunch: still licensed (stored locally, no network request on launch).

## Limitations to confirm

- The live mirror is **view-only**: you cannot click or type into the mirrored content; interact with the real window instead.
- Raise mode is **not** a true floating level. Test full-screen Spaces, Stage Manager, sheets, and popovers separately; a focused foreground window can cover a raise-pinned window until the next app switch. Use live-mirror mode when you need the window to stay visibly on top while you work elsewhere.
- While repeatedly raising an overlapping window (raise mode), confirm keyboard focus remains in the window where the user is typing.
