# Review disposition for PinTop 0.3.0

This release incorporates the useful parts of the external static review while keeping PinTop on documented public APIs.

## Incorporated

- The 250 ms unconditional `AXRaise` loop was too aggressive for a small utility. PinTop now reacts to application activation and supported Accessibility focus/window notifications, with a one-second fallback for missed or unsupported events.
- Opening the menu no longer performs a synchronous title lookup in another process. Title refreshes run on the serialized Accessibility queue, and supported title-change notifications trigger the same asynchronous path.
- The `kill(pid, 0)` liveness probe was removed. PinTop retains the original `NSRunningApplication` object for matching the application-termination notification, while invalid Accessibility elements remain the fallback.
- The menu-selection ambiguity and keyboard-focus behavior are explicitly covered in the documentation and test checklist.

## Partly incorporated

- Event-driven behavior cannot fully replace polling. Application activation does not cover every same-application window reorder, transient panel, or application that omits Accessibility notifications. A one-second fallback remains to preserve the utility's core behavior.
- Accessibility calls that repeatedly operate on the pinned element are serialized. Initial selection and observer lifecycle work still occur on AppKit's main thread; they are bounded by the configured Accessibility timeout and are not part of the repeating path.

## Not incorporated

- Destruction observation remains registered on the selected window element. `AXObserverAddNotification` observes the specified Accessibility object, so direct registration is the clearest match for `kAXUIElementDestroyedNotification`. Application termination and invalid-element checks remain independent fallbacks.
- The extra `DispatchQueue.main.async` in the Carbon hotkey callback remains. It is harmless and makes the AppKit-thread requirement explicit.
- A universal binary and localization are distribution enhancements, not correctness fixes for this personal-use source build.
- `_AXUIElementGetWindow`, `SLSSetWindowLevel`, and other underscored or `SLS` symbols are private APIs. They are intentionally excluded because they are unsupported, can change without compatibility guarantees, and are unsuitable for App Store distribution.
