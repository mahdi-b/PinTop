import ApplicationServices
import Carbon.HIToolbox
import Cocoa
import CoreMedia
import Dispatch
import ScreenCaptureKit

// PinTop supports two ways to keep a window visible:
//
// - .raise   The original behavior. Asks macOS to raise the real window with the public
//            Accessibility AXRaise action plus a one-second fallback. The window stays
//            clickable, but a focused foreground window can cover it until the next app
//            switch. No extra permission beyond Accessibility.
// - .mirror  A live video copy of the chosen window, drawn in a borderless floating panel
//            that PinTop owns. Because it is PinTop's own window, it genuinely stays on top
//            and the real window behind keeps keyboard focus. The mirror is view-only and
//            requires Screen Recording permission. Available on macOS 13 and later.
private enum PinMode: String {
  case raise
  case mirror

  var menuTitle: String {
    switch self {
    case .raise: return "Raise real window (clickable)"
    case .mirror: return "Live video mirror (stays on top)"
    }
  }

  static let defaultsKey = "PinModeSelection"
}

extension String {
  fileprivate var fourCharCodeValue: FourCharCode {
    unicodeScalars.prefix(4).reduce(0) { partial, scalar in
      (partial << 8) + FourCharCode(scalar.value)
    }
  }
}

private struct Shortcut {
  let keyCode: UInt32
  let keyLabel: String
  let modifiers: UInt32
  let signature: FourCharCode
  let identifier: UInt32

  var displayName: String {
    var result = ""
    if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
    if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
    if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
    if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
    return result + keyLabel.uppercased()
  }
}

// Change this one declaration to use a different shortcut.
private let pinShortcut = Shortcut(
  keyCode: UInt32(kVK_ANSI_T),
  keyLabel: "T",
  modifiers: UInt32(cmdKey | optionKey),
  signature: "PINT".fourCharCodeValue,
  identifier: 1
)

private let fallbackRaiseEveryMilliseconds = 1_000
private let fallbackRaiseLeewayMilliseconds = 150
private let accessibilityMessageTimeout: Float = 0.5

// MARK: - Trial and license

// PinTop is free to use for `trialDays`, then requires a one-time license purchased from the
// website. Activation is the ONLY network request the app ever makes: one HTTPS call to the
// Lemon Squeezy license API when the user enters a key, after which the activation is stored
// locally and never re-checked. Everything else stays fully offline.
private enum LicenseConfiguration {
  static let trialDays = 7
  static let purchaseURL = URL(string: "https://pintop.cognitivediscovery.com/#buy")!
  static let activationURL = URL(string: "https://api.lemonsqueezy.com/v1/licenses/activate")!

  // TODO(before public release): set to the real Lemon Squeezy store and product IDs so a
  // key for some other product is rejected. A value of 0 skips that check (development only).
  static let expectedStoreID = 0
  static let expectedProductID = 0
}

private final class LicenseManager {
  enum State: Equatable {
    case licensed
    case trial(daysRemaining: Int)
    case expired
  }

  enum LicenseError: Error {
    case emptyKey
    case network(String)
    case invalidResponse
    case rejected(String)

    var message: String {
      switch self {
      case .emptyKey:
        return "Enter a license key first."
      case .network(let detail):
        return "Could not reach the license server: \(detail)"
      case .invalidResponse:
        return "The license server returned an unexpected response; please try again."
      case .rejected(let detail):
        return detail
      }
    }
  }

  private static let licenseKeyDefaultsKey = "LicenseKey"
  private static let licenseActivatedDefaultsKey = "LicenseActivated"
  private static let trialStartDefaultsKey = "TrialStartDate"

  private let defaults = UserDefaults.standard

  var state: State {
    if defaults.bool(forKey: Self.licenseActivatedDefaultsKey) { return .licensed }

    let dayLength: TimeInterval = 24 * 60 * 60
    let elapsed = Date().timeIntervalSince(trialStart)
    // A clock set backwards counts as day zero rather than extending the trial.
    let daysUsed = max(0, Int(elapsed / dayLength))
    let remaining = LicenseConfiguration.trialDays - daysUsed
    return remaining > 0 ? .trial(daysRemaining: remaining) : .expired
  }

  // The trial start is recorded in UserDefaults and in a marker file in Application Support;
  // the earliest of the two wins and each repairs the other. This is an honesty gate for a
  // $3.99 utility, not DRM — a determined user can reset it, and that is acceptable.
  private var trialStart: Date {
    let fileURL = Self.trialMarkerURL
    let fromDefaults = defaults.object(forKey: Self.trialStartDefaultsKey) as? Date
    let fromFile = (try? String(contentsOf: fileURL, encoding: .utf8))
      .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
      .map { Date(timeIntervalSince1970: $0) }

    if let start = [fromDefaults, fromFile].compactMap({ $0 }).min() {
      if fromDefaults == nil { defaults.set(start, forKey: Self.trialStartDefaultsKey) }
      if fromFile == nil { Self.writeTrialMarker(start, to: fileURL) }
      return start
    }

    let start = Date()
    defaults.set(start, forKey: Self.trialStartDefaultsKey)
    Self.writeTrialMarker(start, to: fileURL)
    return start
  }

  private static var trialMarkerURL: URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support")
    return base.appendingPathComponent("PinTop/.first-launch")
  }

  private static func writeTrialMarker(_ date: Date, to url: URL) {
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try? String(date.timeIntervalSince1970).data(using: .utf8)?.write(to: url)
  }

  // Activates a key against the Lemon Squeezy license API and stores the result locally.
  // `completion` is always called on the main thread.
  func activate(key: String, completion: @escaping (Result<Void, LicenseError>) -> Void) {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      completion(.failure(.emptyKey))
      return
    }

    var request = URLRequest(url: LicenseConfiguration.activationURL)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    var body = URLComponents()
    body.queryItems = [
      URLQueryItem(name: "license_key", value: trimmed),
      URLQueryItem(name: "instance_name", value: "PinTop on \(Host.current().localizedName ?? "Mac")"),
    ]
    request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

    URLSession.shared.dataTask(with: request) { data, _, error in
      let result = Self.parseActivation(data: data, error: error)
      DispatchQueue.main.async {
        if case .success = result {
          self.defaults.set(trimmed, forKey: Self.licenseKeyDefaultsKey)
          self.defaults.set(true, forKey: Self.licenseActivatedDefaultsKey)
        }
        completion(result)
      }
    }.resume()
  }

  private static func parseActivation(data: Data?, error: Error?) -> Result<Void, LicenseError> {
    if let error {
      return .failure(.network(error.localizedDescription))
    }
    guard let data,
      let object = try? JSONSerialization.jsonObject(with: data),
      let json = object as? [String: Any]
    else {
      return .failure(.invalidResponse)
    }

    if let message = json["error"] as? String, !message.isEmpty {
      return .failure(.rejected(message))
    }
    guard json["activated"] as? Bool == true else {
      return .failure(.rejected("The key could not be activated."))
    }

    // Reject keys sold for some other store/product than PinTop's.
    let meta = json["meta"] as? [String: Any]
    let storeID = meta?["store_id"] as? Int ?? -1
    let productID = meta?["product_id"] as? Int ?? -1
    let storeMatches =
      LicenseConfiguration.expectedStoreID == 0
      || storeID == LicenseConfiguration.expectedStoreID
    let productMatches =
      LicenseConfiguration.expectedProductID == 0
      || productID == LicenseConfiguration.expectedProductID
    guard storeMatches, productMatches else {
      return .failure(.rejected("This license key is for a different product."))
    }

    return .success(())
  }
}

private struct PinnedWindow {
  let token = UUID()
  let element: AXUIElement
  let runningApplication: NSRunningApplication
  let processIdentifier: pid_t
  let applicationName: String
  var title: String

  var displayName: String {
    let windowName = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return "\(applicationName): \(windowName.isEmpty ? "Untitled window" : windowName)"
  }

  func isSameWindow(as other: PinnedWindow) -> Bool {
    processIdentifier == other.processIdentifier && CFEqual(element, other.element)
  }
}

// MARK: - Live mirror (ScreenCaptureKit)

// A borderless, non-activating panel. It can be dragged and resized but never becomes the
// key or main window, so the window the user is actually typing in keeps focus while the
// mirror floats above everything.
private final class MirrorPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

// Backing view whose layer displays the captured frames. Resizing the panel keeps the
// content filling the view (the layer is gravity-resized, not redrawn per frame).
private final class MirrorContentView: NSView {
  let videoLayer = CALayer()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    videoLayer.contentsGravity = .resizeAspect
    videoLayer.backgroundColor = NSColor.black.cgColor
    layer?.addSublayer(videoLayer)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layout() {
    super.layout()
    // Match the sublayer to the view bounds without implicit animation so a drag-resize
    // does not trail the window edge.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    videoLayer.frame = bounds
    CATransaction.commit()
  }
}

// Owns one capture stream and one floating panel for the .mirror pin mode. macOS 13+.
//
// Threading: the controller is @MainActor, so the panel, lifecycle (start/stop), and
// onSourceLost handling all run on the main thread. ScreenCaptureKit delivers frames on a
// private serial queue; the frame and stop callbacks are nonisolated. Each frame's pixel
// buffer is handed to a standalone display layer via CALayer.contents inside a CATransaction
// (safe off-main because nothing else mutates that layer's contents); the stop callback only
// bounces to the main thread to fire onSourceLost.
@available(macOS 13.0, *)
private final class MirrorController: NSObject, SCStreamDelegate, SCStreamOutput {
  // Called on the main thread when the captured window goes away or the stream dies, so the
  // app delegate can clear the pin and update its UI. Assigned and read on the main thread.
  var onSourceLost: (() -> Void)?

  private let panel: MirrorPanel
  private let contentView: MirrorContentView
  private let sampleQueue = DispatchQueue(label: "com.local.pintop.mirror.frames", qos: .userInitiated)

  // The frame callback arrives on `sampleQueue`; it only touches this standalone display
  // layer, which is safe to update off the main thread because nothing else writes it.
  private let videoLayer: CALayer

  // `stream` is created and torn down on the main thread only.
  private var stream: SCStream?

  // The window resolved by the app delegate at pin time; capture starts directly from it.
  private let sourceWindow: SCWindow
  let displayName: String

  init(window: SCWindow, displayName: String) {
    self.sourceWindow = window
    self.displayName = displayName

    let initialFrame = MirrorController.initialPanelFrame(for: window)
    panel = MirrorPanel(
      contentRect: initialFrame,
      styleMask: [.borderless, .nonactivatingPanel, .resizable],
      backing: .buffered,
      defer: false
    )
    contentView = MirrorContentView(frame: NSRect(origin: .zero, size: initialFrame.size))
    videoLayer = contentView.videoLayer

    super.init()

    panel.contentView = contentView
    panel.isReleasedWhenClosed = false
    panel.isMovableByWindowBackground = true
    panel.hasShadow = true
    panel.backgroundColor = .black
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    // Keep the mirror visible even when PinTop is not the active app.
    panel.hidesOnDeactivate = false
    panel.title = displayName
  }

  // MARK: Lifecycle (main thread)

  // Starts capture of the window chosen at init asynchronously, then shows the panel on the
  // main thread. `completion` is always called on the main thread with the result. Call on main.
  func start(completion: @escaping (Result<Void, Error>) -> Void) {
    precondition(Thread.isMainThread)

    let scale = effectiveScale
    let scWindow = sourceWindow

    Task {
      do {
        // Capture at the source window's native pixel size (capped) so enlarging the mirror
        // panel still looks sharp. SCWindow.frame is in points.
        let maxPixelDimension = 4096
        let pixelWidth = min(maxPixelDimension, max(2, Int(scWindow.frame.width * scale)))
        let pixelHeight = min(maxPixelDimension, max(2, Int(scWindow.frame.height * scale)))

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let configuration = SCStreamConfiguration()
        configuration.width = pixelWidth
        configuration.height = pixelHeight
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.queueDepth = 5

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await newStream.startCapture()

        await MainActor.run {
          self.stream = newStream
          self.panel.orderFrontRegardless()
          completion(.success(()))
        }
      } catch {
        await MainActor.run { completion(.failure(error)) }
      }
    }
  }

  func stop() {
    precondition(Thread.isMainThread)
    panel.orderOut(nil)
    panel.close()

    guard let stream else { return }
    self.stream = nil
    // Best-effort async teardown; the UI is already gone synchronously.
    Task { try? await stream.stopCapture() }
  }

  // The panel may not be on a screen yet when capture starts, so its backingScaleFactor can
  // read as 1. Fall back to the main screen's scale so the capture isn't half-resolution.
  private var effectiveScale: CGFloat {
    if panel.backingScaleFactor > 1 { return panel.backingScaleFactor }
    return NSScreen.main?.backingScaleFactor ?? 2
  }

  // MARK: SCStreamOutput (sample queue)

  func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .screen, sampleBuffer.isValid else { return }

    // Drop frames whose status is not "complete" (e.g. blank/occluded notices).
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
      as? [[SCStreamFrameInfo: Any]],
      let statusRaw = attachments.first?[.status] as? Int,
      let status = SCFrameStatus(rawValue: statusRaw),
      status != .complete
    {
      return
    }

    guard let imageBuffer = sampleBuffer.imageBuffer else { return }
    let surface = CVPixelBufferGetIOSurface(imageBuffer)?.takeUnretainedValue()

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    videoLayer.contents = surface
    CATransaction.commit()
  }

  // MARK: SCStreamDelegate (any thread)

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    DispatchQueue.main.async { [weak self] in
      self?.onSourceLost?()
    }
  }

  // MARK: Helpers

  // How far the mirror is shifted from the source window so a strip of the original stays
  // visible (and clickable, to refocus the real window). Change this one value to taste.
  private static let revealOffset: CGFloat = 100

  // The mirror opens at the source window's size, on top of it but shifted diagonally by
  // `revealOffset`. The shift goes toward whichever side of the screen has room, and the
  // final frame is clamped to that screen's visible area so the panel is always reachable.
  private static func initialPanelFrame(for window: SCWindow) -> NSRect {
    // SCWindow.frame uses CoreGraphics screen coordinates (origin at the primary display's
    // top-left, y increasing downward); AppKit places windows in Cocoa coordinates (origin at
    // the primary display's bottom-left, y increasing upward). Convert via the primary
    // display's height — NSScreen.screens.first, not NSScreen.main, is the primary.
    let source = window.frame
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    var frame = NSRect(
      x: source.origin.x,
      y: primaryHeight - source.origin.y - source.height,
      width: max(source.width > 0 ? source.width : 480, 200),
      height: max(source.height > 0 ? source.height : 320, 140)
    )

    let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
    guard let visible = screen?.visibleFrame else {
      return frame.offsetBy(dx: revealOffset, dy: -revealOffset)
    }

    // Prefer shifting right and down (revealing the original's left/top edges); flip a
    // direction when the screen has no room on that side.
    frame.origin.x += (frame.maxX + revealOffset <= visible.maxX) ? revealOffset : -revealOffset
    frame.origin.y += (frame.minY - revealOffset >= visible.minY) ? -revealOffset : revealOffset

    frame.size.width = min(frame.width, visible.width)
    frame.size.height = min(frame.height, visible.height)
    frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
    frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
    return frame
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let statusMenu = NSMenu()
  private let licenseManager = LicenseManager()

  // Ongoing cross-process Accessibility calls for the pinned element are serialized here.
  private let accessibilityQueue = DispatchQueue(
    label: "com.local.pintop.accessibility",
    qos: .userInitiated
  )
  private var raiseTimer: DispatchSourceTimer?

  // The pinned Accessibility element is read by both the main thread and accessibilityQueue.
  // The same lock guards the coalescing flags below so a flurry of triggers collapses into
  // at most one in-flight raise and one in-flight title read.
  private let stateLock = NSLock()
  private var pinnedWindowStorage: PinnedWindow?
  private var raiseIsPending = false
  private var titleRefreshIsPending = false

  private var hotKeyReference: EventHotKeyRef?
  private var eventHandlerReference: EventHandlerRef?
  private var hotKeyIsRegistered = false
  private var workspaceObservers: [NSObjectProtocol] = []
  private var lastExternalApplication: NSRunningApplication?

  // The pin mode chosen for the next pin. Persisted across launches.
  private var pinMode: PinMode = .raise
  // Active live-video mirror, when the current pin uses .mirror. Stored as AnyObject so the
  // stored property itself does not require macOS 13; cast back under `if #available`.
  private var activeMirror: AnyObject?
  // Mirror whose capture is still starting. Only the most recent request may be adopted when
  // its start completes; a superseded or invalidated start is stopped instead, so it cannot
  // leave behind an orphaned floating panel with a live capture stream. Main thread only.
  private var pendingMirror: AnyObject?

  private struct ObservedNotification {
    let element: AXUIElement
    let name: CFString
  }

  private var windowObserver: AXObserver?
  private var observedNotifications: [ObservedNotification] = []

  private var statusMessage = "Ready — focus a window and press \(pinShortcut.displayName)."
  private var feedbackResetWorkItem: DispatchWorkItem?

  private static let accessibilityNotificationCallback: AXObserverCallback = {
    observer, element, notification, refcon in
    guard let refcon else { return }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
    delegate.handleAccessibilityNotification(
      observer: observer,
      element: element,
      notification: notification
    )
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    loadPinMode()
    configureStatusItem()
    startWorkspaceTracking()
    let hotKeyReady = registerHotKey()

    let accessibilityReady = ensureAccessibilityPermission(prompt: true)
    if hotKeyReady && !accessibilityReady {
      setFeedback(
        "Accessibility permission is required. Open the PinTop menu for settings.",
        isError: true
      )
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    feedbackResetWorkItem?.cancel()

    raiseTimer?.setEventHandler {}
    raiseTimer?.cancel()
    raiseTimer = nil

    stopObservingPinnedWindow()
    stopActiveMirror()

    if let hotKeyReference {
      UnregisterEventHotKey(hotKeyReference)
    }
    if let eventHandlerReference {
      RemoveEventHandler(eventHandlerReference)
    }

    let center = NSWorkspace.shared.notificationCenter
    workspaceObservers.forEach(center.removeObserver)
    workspaceObservers.removeAll()
  }

  // MARK: - Pin mode

  private func loadPinMode() {
    if let raw = UserDefaults.standard.string(forKey: PinMode.defaultsKey),
      let mode = PinMode(rawValue: raw)
    {
      // Fall back to .raise if a persisted .mirror selection can't run on this OS.
      pinMode = (mode == .mirror && !mirrorModeAvailable) ? .raise : mode
    }
  }

  private func setPinMode(_ mode: PinMode) {
    precondition(Thread.isMainThread)
    guard mode != pinMode else { return }
    pinMode = mode
    UserDefaults.standard.set(mode.rawValue, forKey: PinMode.defaultsKey)
    rebuildMenu()
  }

  private var mirrorModeAvailable: Bool {
    if #available(macOS 13.0, *) { return true }
    return false
  }

  @objc private func selectRaiseMode() { setPinMode(.raise) }
  @objc private func selectMirrorMode() { setPinMode(.mirror) }

  // MARK: - Live mirror lifecycle

  private var hasActiveMirror: Bool { activeMirror != nil }

  // Description of whatever is currently pinned in either mode, for menu/status text.
  private func currentPinDisplayName() -> String? {
    if let pinned = pinnedWindowSnapshot() { return pinned.displayName }
    if #available(macOS 13.0, *), let mirror = activeMirror as? MirrorController {
      return mirror.displayName
    }
    return nil
  }

  private var isAnythingPinned: Bool {
    pinnedWindowSnapshot() != nil || hasActiveMirror
  }

  private func stopActiveMirror() {
    precondition(Thread.isMainThread)
    guard let mirror = activeMirror else { return }
    activeMirror = nil
    if #available(macOS 13.0, *), let controller = mirror as? MirrorController {
      controller.stop()
    }
  }

  // MARK: - Menu and status item

  private func configureStatusItem() {
    statusMenu.autoenablesItems = false
    statusMenu.delegate = self
    statusItem.menu = statusMenu
    updateStatusItemIcon()
    rebuildMenu()
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    requestPinnedWindowTitleRefresh()
    rebuildMenu()
  }

  private func rebuildMenu() {
    statusMenu.removeAllItems()

    let toggleItem = NSMenuItem(
      title: "Pin or Unpin Focused Window",
      action: #selector(toggleFocusedWindow),
      keyEquivalent: ""
    )
    toggleItem.target = self
    statusMenu.addItem(toggleItem)

    let shortcutTitle =
      hotKeyIsRegistered
      ? "Shortcut: \(pinShortcut.displayName)"
      : "Shortcut unavailable: \(pinShortcut.displayName)"
    let shortcutItem = NSMenuItem(
      title: shortcutTitle,
      action: nil,
      keyEquivalent: ""
    )
    shortcutItem.isEnabled = false
    statusMenu.addItem(shortcutItem)

    statusMenu.addItem(buildPinModeMenuItem())
    statusMenu.addItem(.separator())

    let pinStateItem: NSMenuItem
    if let name = currentPinDisplayName() {
      let modeLabel = hasActiveMirror ? "Mirroring" : "Pinned"
      pinStateItem = NSMenuItem(
        title: "\(modeLabel): \(name)",
        action: nil,
        keyEquivalent: ""
      )
    } else {
      pinStateItem = NSMenuItem(title: "No window pinned", action: nil, keyEquivalent: "")
    }
    pinStateItem.isEnabled = false
    statusMenu.addItem(pinStateItem)

    let unpinItem = NSMenuItem(
      title: "Unpin Window", action: #selector(unpinWindow), keyEquivalent: "")
    unpinItem.target = self
    unpinItem.isEnabled = isAnythingPinned
    statusMenu.addItem(unpinItem)

    statusMenu.addItem(.separator())

    let status = NSMenuItem(title: "Status: \(statusMessage)", action: nil, keyEquivalent: "")
    status.isEnabled = false
    statusMenu.addItem(status)

    let permissionTitle =
      AXIsProcessTrusted()
      ? "Accessibility Permission: Granted"
      : "Open Accessibility Settings…"
    let permissionItem = NSMenuItem(
      title: permissionTitle,
      action: #selector(openAccessibilitySettings),
      keyEquivalent: ""
    )
    permissionItem.target = self
    statusMenu.addItem(permissionItem)

    // Screen Recording is only relevant to the live-mirror mode; surface it when selected.
    if pinMode == .mirror && mirrorModeAvailable {
      let screenTitle =
        CGPreflightScreenCaptureAccess()
        ? "Screen Recording Permission: Granted"
        : "Open Screen Recording Settings…"
      let screenItem = NSMenuItem(
        title: screenTitle,
        action: #selector(openScreenRecordingSettings),
        keyEquivalent: ""
      )
      screenItem.target = self
      statusMenu.addItem(screenItem)
    }

    statusMenu.addItem(.separator())
    addLicenseMenuItems()
    statusMenu.addItem(.separator())

    let aboutItem = NSMenuItem(
      title: "About PinTop", action: #selector(showAbout), keyEquivalent: "")
    aboutItem.target = self
    statusMenu.addItem(aboutItem)

    let quitItem = NSMenuItem(title: "Quit PinTop", action: #selector(quit), keyEquivalent: "q")
    quitItem.target = self
    statusMenu.addItem(quitItem)
  }

  // Trial/license status plus purchase actions. Once licensed, the purchase items disappear.
  private func addLicenseMenuItems() {
    func addDisabled(_ title: String) {
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      item.isEnabled = false
      statusMenu.addItem(item)
    }

    switch licenseManager.state {
    case .licensed:
      addDisabled("License: Active")
      return
    case .trial(let daysRemaining):
      addDisabled("Free trial: \(daysRemaining) day\(daysRemaining == 1 ? "" : "s") left")
    case .expired:
      addDisabled("Free trial ended — pinning is disabled")
    }

    let buyItem = NSMenuItem(
      title: "Buy PinTop ($3.99)…", action: #selector(buyPinTop), keyEquivalent: "")
    buyItem.target = self
    statusMenu.addItem(buyItem)

    let keyItem = NSMenuItem(
      title: "Enter License Key…", action: #selector(enterLicenseKey), keyEquivalent: "")
    keyItem.target = self
    statusMenu.addItem(keyItem)
  }

  @objc private func buyPinTop() {
    NSWorkspace.shared.open(LicenseConfiguration.purchaseURL)
  }

  @objc private func enterLicenseKey() {
    // As an accessory app, PinTop must activate itself or the dialog opens behind other apps.
    NSApp.activate(ignoringOtherApps: true)

    let alert = NSAlert()
    alert.messageText = "Enter License Key"
    alert.informativeText =
      "Paste the license key from your purchase email. Activation contacts the license "
      + "server once; PinTop makes no other network requests."
    alert.addButton(withTitle: "Activate")
    alert.addButton(withTitle: "Cancel")

    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    field.placeholderString = "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
    alert.accessoryView = field
    alert.window.initialFirstResponder = field

    guard alert.runModal() == .alertFirstButtonReturn else { return }

    setFeedback("Checking license key…")
    licenseManager.activate(key: field.stringValue) { [weak self] result in
      guard let self else { return }
      switch result {
      case .success:
        self.setFeedback("License activated — thank you for buying PinTop!")
      case .failure(let error):
        self.setFeedback(error.message, isError: true)
      }
    }
  }

  // Blocks creating new pins after the trial ends; unpinning and existing pins still work.
  private func ensurePinningAllowed() -> Bool {
    switch licenseManager.state {
    case .licensed, .trial:
      return true
    case .expired:
      setFeedback(
        "Free trial ended. Buy PinTop ($3.99) or enter a license key from the menu.",
        isError: true
      )
      return false
    }
  }

  // The standard About panel shows the app icon, name, version/build from Info.plist, and the
  // CognitiveDiscovery LLC copyright line. As an accessory (menu-bar) app, PinTop must
  // activate itself first or the panel would open behind the frontmost app.
  @objc private func showAbout() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel(nil)
  }

  // Submenu that switches the mode used for the next pin. The live-mirror entry is disabled
  // (with an explanation) on macOS versions that lack ScreenCaptureKit single-window capture.
  private func buildPinModeMenuItem() -> NSMenuItem {
    let modeItem = NSMenuItem(title: "Pin Mode", action: nil, keyEquivalent: "")
    let submenu = NSMenu()
    submenu.autoenablesItems = false

    let raiseItem = NSMenuItem(
      title: PinMode.raise.menuTitle,
      action: #selector(selectRaiseMode),
      keyEquivalent: ""
    )
    raiseItem.target = self
    raiseItem.state = pinMode == .raise ? .on : .off
    submenu.addItem(raiseItem)

    let mirrorItem = NSMenuItem(
      title: PinMode.mirror.menuTitle,
      action: #selector(selectMirrorMode),
      keyEquivalent: ""
    )
    mirrorItem.target = self
    mirrorItem.state = pinMode == .mirror ? .on : .off
    mirrorItem.isEnabled = mirrorModeAvailable
    submenu.addItem(mirrorItem)

    if !mirrorModeAvailable {
      let note = NSMenuItem(
        title: "Live mirror needs macOS 13 or later", action: nil, keyEquivalent: "")
      note.isEnabled = false
      submenu.addItem(note)
    }

    modeItem.submenu = submenu
    return modeItem
  }

  private func updateStatusItemIcon(showWarning: Bool = false) {
    guard let button = statusItem.button else { return }

    let isPinned = isAnythingPinned
    let symbolName = showWarning ? "exclamationmark.triangle" : (isPinned ? "pin.fill" : "pin")
    let description =
      showWarning
      ? "PinTop warning"
      : (isPinned ? "PinTop — window pinned" : "PinTop — no window pinned")

    if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description) {
      image.isTemplate = true
      button.image = image
      button.title = ""
    } else {
      button.image = nil
      button.title = showWarning ? "⚠︎" : (isPinned ? "📍" : "📌")
    }
    button.toolTip = "PinTop — \(statusMessage)"
  }

  private func setFeedback(_ message: String, isError: Bool = false) {
    precondition(Thread.isMainThread)

    statusMessage = message
    feedbackResetWorkItem?.cancel()
    updateStatusItemIcon(showWarning: isError)
    rebuildMenu()

    guard isError else { return }
    NSSound.beep()

    let workItem = DispatchWorkItem { [weak self] in
      self?.updateStatusItemIcon()
    }
    feedbackResetWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: workItem)
  }

  // MARK: - Hotkey

  @discardableResult
  private func registerHotKey() -> Bool {
    var eventSpec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    let selfPointer = Unmanaged.passUnretained(self).toOpaque()

    let handlerStatus = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, eventReference, userData in
        guard let eventReference, let userData else { return noErr }

        var hotKeyID = EventHotKeyID()
        let parameterStatus = GetEventParameter(
          eventReference,
          EventParamName(kEventParamDirectObject),
          EventParamType(typeEventHotKeyID),
          nil,
          MemoryLayout<EventHotKeyID>.size,
          nil,
          &hotKeyID
        )

        guard parameterStatus == noErr,
          hotKeyID.signature == pinShortcut.signature,
          hotKeyID.id == pinShortcut.identifier
        else {
          return noErr
        }

        let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
        DispatchQueue.main.async {
          delegate.toggleFocusedWindow()
        }
        return noErr
      },
      1,
      &eventSpec,
      selfPointer,
      &eventHandlerReference
    )

    guard handlerStatus == noErr else {
      setFeedback(
        "Could not install the global shortcut handler (error \(handlerStatus)).",
        isError: true
      )
      return false
    }

    let hotKeyID = EventHotKeyID(
      signature: pinShortcut.signature,
      id: pinShortcut.identifier
    )
    let registrationStatus = RegisterEventHotKey(
      pinShortcut.keyCode,
      pinShortcut.modifiers,
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &hotKeyReference
    )

    guard registrationStatus == noErr else {
      if let eventHandlerReference {
        RemoveEventHandler(eventHandlerReference)
        self.eventHandlerReference = nil
      }
      setFeedback(
        "Could not register \(pinShortcut.displayName); another app may already use it (error \(registrationStatus)).",
        isError: true
      )
      return false
    }

    hotKeyIsRegistered = true
    return true
  }

  // MARK: - Pinning

  @objc private func toggleFocusedWindow() {
    // A live mirror has no "same focused window" to compare against; toggling always ends it.
    if hasActiveMirror {
      let name = currentPinDisplayName() ?? "window"
      stopActiveMirror()
      updateStatusItemIcon()
      setFeedback("Unpinned \(name).")
      return
    }

    guard ensureAccessibilityPermission(prompt: true) else {
      setFeedback(
        "Accessibility permission is required. Open the PinTop menu for settings.",
        isError: true
      )
      return
    }

    guard let candidate = currentFocusedWindow() else {
      setFeedback(
        "No usable window found. Click a normal app window, then press \(pinShortcut.displayName).",
        isError: true
      )
      return
    }

    // Re-pressing while the same window is raise-pinned unpins it.
    if let current = pinnedWindowSnapshot(), current.isSameWindow(as: candidate) {
      setPinnedWindow(nil)
      setFeedback("Unpinned \(current.displayName).")
      return
    }

    guard ensurePinningAllowed() else { return }

    switch pinMode {
    case .raise:
      pinWithRaise(candidate)
    case .mirror:
      pinWithMirror(candidate)
    }
  }

  private func pinWithRaise(_ candidate: PinnedWindow) {
    let raiseError = validateAndRaise(candidate.element)
    guard raiseError == .success else {
      setFeedback(
        "Could not pin \(candidate.displayName): \(description(for: raiseError)).",
        isError: true
      )
      return
    }

    setPinnedWindow(candidate)
    setFeedback("Pinned \(candidate.displayName).")
  }

  // Start a live-video mirror of the candidate window in a floating panel. Requires macOS 13+
  // and Screen Recording permission; resolving the window and starting capture are async.
  private func pinWithMirror(_ candidate: PinnedWindow) {
    guard #available(macOS 13.0, *) else {
      setFeedback("Live mirror needs macOS 13 or later.", isError: true)
      return
    }

    // Clear any existing raise pin so only one thing is ever pinned.
    if pinnedWindowSnapshot() != nil {
      setPinnedWindow(nil)
    }

    guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
      setFeedback(
        "Screen Recording permission is required for live mirror. Open the PinTop menu for settings.",
        isError: true
      )
      return
    }

    setFeedback("Starting live mirror of \(candidate.displayName)…")
    let pid = candidate.processIdentifier
    let sourceTitle = candidate.title
    let displayName = candidate.displayName

    // Resolve the source window, then start capture. Both steps report back on the main thread.
    Task { @MainActor in
      let scWindow: SCWindow?
      do {
        scWindow = try await self.shareableWindow(forPID: pid, matchingTitle: sourceTitle)
      } catch {
        self.setFeedback(
          "Could not start live mirror: \(error.localizedDescription)", isError: true)
        return
      }

      guard let scWindow else {
        self.setFeedback("Could not find a capturable window for \(displayName).", isError: true)
        return
      }

      let controller = MirrorController(window: scWindow, displayName: displayName)
      controller.onSourceLost = { [weak self, weak controller] in
        guard let self, let controller, self.activeMirror === controller else { return }
        self.stopActiveMirror()
        self.updateStatusItemIcon()
        self.setFeedback("The mirrored window closed; the mirror was cleared.")
      }

      // Mark this start as the one allowed to become the active mirror. A newer pin (mirror
      // or raise) replaces or clears this reference, which tells the completion below to
      // discard its controller instead of adopting it.
      self.pendingMirror = controller

      controller.start { [weak self] result in
        guard let self else { return }
        let isCurrentRequest = self.pendingMirror === controller
        if isCurrentRequest { self.pendingMirror = nil }

        switch result {
        case .success:
          // Adopt only if no newer request superseded this start and nothing was raise-pinned
          // while capture was starting; otherwise tear the finished stream back down.
          guard isCurrentRequest, self.pinnedWindowSnapshot() == nil else {
            controller.stop()
            return
          }
          self.stopActiveMirror()
          self.activeMirror = controller
          self.updateStatusItemIcon()
          self.setFeedback("Mirroring \(displayName).")
        case .failure(let error):
          controller.stop()
          if isCurrentRequest {
            self.setFeedback(
              "Could not start live mirror: \(error.localizedDescription)", isError: true)
          }
        }
      }
    }
  }

  // Find the window to mirror among the given process's on-screen windows, as a
  // ScreenCaptureKit window. A window whose title matches the Accessibility title of the
  // window the user actually focused is preferred, so multi-window apps (floating panels,
  // picture-in-picture) mirror the right one. Otherwise fall back to the first match:
  // ScreenCaptureKit lists windows front-to-back, so that is the frontmost. We match by owning
  // PID and title rather than a private AX→CGWindowID bridge.
  @available(macOS 13.0, *)
  private func shareableWindow(forPID pid: pid_t, matchingTitle title: String) async throws
    -> SCWindow?
  {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false,
      onScreenWindowsOnly: true
    )
    let candidates = content.windows.filter { window in
      window.owningApplication?.processID == pid
        && window.isOnScreen
        && window.frame.width > 1
        && window.frame.height > 1
    }

    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedTitle.isEmpty,
      let byTitle = candidates.first(where: {
        $0.title?.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedTitle
      })
    {
      return byTitle
    }
    return candidates.first
  }

  @objc private func unpinWindow() {
    if hasActiveMirror {
      let name = currentPinDisplayName() ?? "window"
      stopActiveMirror()
      updateStatusItemIcon()
      setFeedback("Unpinned \(name).")
      return
    }
    guard let pinned = pinnedWindowSnapshot() else { return }
    setPinnedWindow(nil)
    setFeedback("Unpinned \(pinned.displayName).")
  }

  private func validateAndRaise(_ element: AXUIElement) -> AXError {
    var actionsReference: CFArray?
    let actionsError = AXUIElementCopyActionNames(element, &actionsReference)

    if actionsError == .success,
      let actionNames = actionsReference,
      !coreFoundationArray(actionNames, contains: kAXRaiseAction as CFString)
    {
      return .actionUnsupported
    }

    // If action discovery itself fails, the action call remains the source of truth.
    return AXUIElementPerformAction(element, kAXRaiseAction as CFString)
  }

  private func startRaiseTimer() {
    guard raiseTimer == nil else { return }

    let timer = DispatchSource.makeTimerSource(queue: accessibilityQueue)
    timer.schedule(
      deadline: .now() + .milliseconds(fallbackRaiseEveryMilliseconds),
      repeating: .milliseconds(fallbackRaiseEveryMilliseconds),
      leeway: .milliseconds(fallbackRaiseLeewayMilliseconds)
    )
    timer.setEventHandler { [weak self] in
      self?.raisePinnedWindow()
    }
    raiseTimer = timer
    timer.resume()
  }

  private func stopRaiseTimer() {
    raiseTimer?.setEventHandler {}
    raiseTimer?.cancel()
    raiseTimer = nil
  }

  private func raisePinnedWindow() {
    guard let pinned = pinnedWindowSnapshot() else { return }

    let error = AXUIElementPerformAction(pinned.element, kAXRaiseAction as CFString)
    switch error {
    case .success:
      return
    case .invalidUIElement:
      clearPinnedWindowFromBackground(
        token: pinned.token,
        message: "The pinned window closed; the pin was cleared."
      )
    case .apiDisabled:
      clearPinnedWindowFromBackground(
        token: pinned.token,
        message: "Accessibility permission is no longer available; the pin was cleared."
      )
    case .actionUnsupported, .notImplemented:
      clearPinnedWindowFromBackground(
        token: pinned.token,
        message: "This window no longer supports being raised; the pin was cleared."
      )
    default:
      // Errors such as cannotComplete can be transient while an app is busy.
      // Keep the pin and retry at the next interval.
      return
    }
  }

  private func requestImmediateRaise() {
    // Collapse a burst of triggers (activation plus focus/main-window changes that can all
    // fire for one logical event) into a single queued raise. The first request enqueues the
    // work and marks it pending; later requests that arrive before it runs do nothing.
    stateLock.lock()
    guard pinnedWindowStorage != nil, !raiseIsPending else {
      stateLock.unlock()
      return
    }
    raiseIsPending = true
    stateLock.unlock()

    accessibilityQueue.async { [weak self] in
      guard let self else { return }
      // Clear the flag before raising so a trigger that arrives mid-raise schedules a fresh
      // raise rather than being dropped. The serial queue keeps these ordered.
      self.stateLock.lock()
      self.raiseIsPending = false
      self.stateLock.unlock()

      self.raisePinnedWindow()
    }
  }

  private func coreFoundationArray(_ array: CFArray, contains target: CFString) -> Bool {
    for index in 0..<CFArrayGetCount(array) {
      guard let rawValue = CFArrayGetValueAtIndex(array, index) else { continue }
      let value = unsafeBitCast(rawValue, to: CFTypeRef.self)
      if CFGetTypeID(value) == CFStringGetTypeID(), CFEqual(value, target) {
        return true
      }
    }
    return false
  }

  private func clearPinnedWindowFromBackground(token: UUID, message: String) {
    DispatchQueue.main.async { [weak self] in
      guard let self,
        let current = self.pinnedWindowSnapshot(),
        current.token == token
      else { return }
      self.setPinnedWindow(nil)
      self.setFeedback(message)
    }
  }

  // MARK: - Focused window discovery

  private func currentFocusedWindow() -> PinnedWindow? {
    guard let (applicationElement, processIdentifier) = focusedExternalApplication() else {
      return nil
    }

    _ = AXUIElementSetMessagingTimeout(applicationElement, accessibilityMessageTimeout)

    var windowReference: CFTypeRef?
    let focusedWindowError = AXUIElementCopyAttributeValue(
      applicationElement,
      kAXFocusedWindowAttribute as CFString,
      &windowReference
    )
    guard focusedWindowError == .success,
      let windowElement = accessibilityElement(from: windowReference)
    else {
      return nil
    }

    _ = AXUIElementSetMessagingTimeout(windowElement, accessibilityMessageTimeout)

    guard let runningApplication = NSRunningApplication(processIdentifier: processIdentifier) else {
      return nil
    }
    let applicationName = runningApplication.localizedName ?? "Application"
    let title = stringAttribute(windowElement, kAXTitleAttribute as CFString) ?? ""

    return PinnedWindow(
      element: windowElement,
      runningApplication: runningApplication,
      processIdentifier: processIdentifier,
      applicationName: applicationName,
      title: title
    )
  }

  private func focusedExternalApplication() -> (AXUIElement, pid_t)? {
    let systemWideElement = AXUIElementCreateSystemWide()
    var applicationReference: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(
      systemWideElement,
      kAXFocusedApplicationAttribute as CFString,
      &applicationReference
    )

    if error == .success,
      let applicationElement = accessibilityElement(from: applicationReference),
      let processIdentifier = processIdentifier(of: applicationElement),
      processIdentifier != ProcessInfo.processInfo.processIdentifier
    {
      lastExternalApplication = NSRunningApplication(processIdentifier: processIdentifier)
      return (applicationElement, processIdentifier)
    }

    guard let application = lastExternalApplication,
      !application.isTerminated,
      application.processIdentifier != ProcessInfo.processInfo.processIdentifier
    else {
      return nil
    }

    let processIdentifier = application.processIdentifier
    return (AXUIElementCreateApplication(processIdentifier), processIdentifier)
  }

  private func accessibilityElement(from value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
      return nil
    }
    return (value as! AXUIElement)
  }

  private func processIdentifier(of element: AXUIElement) -> pid_t? {
    var processIdentifier: pid_t = 0
    guard AXUIElementGetPid(element, &processIdentifier) == .success,
      processIdentifier > 0
    else {
      return nil
    }
    return processIdentifier
  }

  private func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
      return nil
    }
    return value as? String
  }

  private func requestPinnedWindowTitleRefresh(expectedElement: AXUIElement? = nil) {
    // Coalesce rapid title changes (a terminal running a long command, a busy browser) into at
    // most one in-flight cross-process read for the current pin. The pending flag is reset when
    // the pin changes (see setPinnedWindow), so a new pin always gets a fresh read.
    stateLock.lock()
    guard let pinned = pinnedWindowStorage else {
      stateLock.unlock()
      return
    }
    if let expectedElement, !CFEqual(pinned.element, expectedElement) {
      stateLock.unlock()
      return
    }
    guard !titleRefreshIsPending else {
      stateLock.unlock()
      return
    }
    titleRefreshIsPending = true
    let token = pinned.token
    stateLock.unlock()

    accessibilityQueue.async { [weak self] in
      guard let self else { return }
      // Clear before reading so a title change arriving mid-read schedules a fresh read.
      self.stateLock.lock()
      self.titleRefreshIsPending = false
      self.stateLock.unlock()

      guard let current = self.pinnedWindowSnapshot(),
        current.token == token,
        let currentTitle = self.stringAttribute(
          current.element,
          kAXTitleAttribute as CFString
        ),
        currentTitle != current.title
      else {
        return
      }

      DispatchQueue.main.async { [weak self] in
        guard let self else { return }

        var didUpdate = false
        self.stateLock.lock()
        if var latest = self.pinnedWindowStorage, latest.token == token {
          latest.title = currentTitle
          self.pinnedWindowStorage = latest
          didUpdate = true
        }
        self.stateLock.unlock()

        if didUpdate {
          self.rebuildMenu()
          self.updateStatusItemIcon()
        }
      }
    }
  }

  // MARK: - Shared state

  private func pinnedWindowSnapshot() -> PinnedWindow? {
    stateLock.lock()
    defer { stateLock.unlock() }
    return pinnedWindowStorage
  }

  private func setPinnedWindow(_ window: PinnedWindow?) {
    precondition(Thread.isMainThread)

    // Only one thing is ever pinned across both modes: adopting a raise pin ends any mirror,
    // including one whose capture is still starting (its completion sees the cleared reference
    // and stops itself).
    if window != nil {
      stopActiveMirror()
      pendingMirror = nil
    }

    stopRaiseTimer()
    stopObservingPinnedWindow()

    stateLock.lock()
    pinnedWindowStorage = window
    // Reset coalescing flags so a pending raise/read tied to the previous pin cannot suppress
    // work for the new one. Any in-flight queue task re-checks the snapshot/token and no-ops.
    raiseIsPending = false
    titleRefreshIsPending = false
    stateLock.unlock()

    if let window {
      startObservingPinnedWindow(window)
      startRaiseTimer()
    }

    updateStatusItemIcon()
    rebuildMenu()
  }

  private func startObservingPinnedWindow(_ window: PinnedWindow) {
    var observer: AXObserver?
    let createError = AXObserverCreate(
      window.processIdentifier,
      Self.accessibilityNotificationCallback,
      &observer
    )
    guard createError == .success, let observer else { return }

    let applicationElement = AXUIElementCreateApplication(window.processIdentifier)
    _ = AXUIElementSetMessagingTimeout(applicationElement, accessibilityMessageTimeout)

    let selfPointer = Unmanaged.passUnretained(self).toOpaque()
    var registrations: [ObservedNotification] = []

    func register(_ element: AXUIElement, _ name: CFString) {
      let error = AXObserverAddNotification(observer, element, name, selfPointer)
      if error == .success {
        registrations.append(ObservedNotification(element: element, name: name))
      }
    }

    // Observe the selected element directly for its own lifecycle and title.
    register(window.element, kAXUIElementDestroyedNotification as CFString)
    register(window.element, kAXTitleChangedNotification as CFString)

    // These application-level events handle common same-app z-order changes promptly.
    // kAXWindowCreatedNotification is intentionally NOT observed: raising on it pushes the
    // pinned window over the app's own new modal dialogs, save panels, and Preferences
    // windows that the user needs. A new window that actually takes focus fires
    // focused-/main-window-changed instead, and the one-second fallback covers the rest.
    register(applicationElement, kAXFocusedWindowChangedNotification as CFString)
    register(applicationElement, kAXMainWindowChangedNotification as CFString)

    guard !registrations.isEmpty else { return }

    windowObserver = observer
    observedNotifications = registrations
    CFRunLoopAddSource(
      CFRunLoopGetMain(),
      AXObserverGetRunLoopSource(observer),
      .defaultMode
    )
  }

  private func stopObservingPinnedWindow() {
    guard let observer = windowObserver else {
      observedNotifications.removeAll()
      return
    }

    let registrations = observedNotifications
    windowObserver = nil
    observedNotifications.removeAll()

    for registration in registrations {
      _ = AXObserverRemoveNotification(
        observer,
        registration.element,
        registration.name
      )
    }

    CFRunLoopRemoveSource(
      CFRunLoopGetMain(),
      AXObserverGetRunLoopSource(observer),
      .defaultMode
    )
  }

  private func handleAccessibilityNotification(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString
  ) {
    guard let currentObserver = windowObserver, CFEqual(currentObserver, observer) else {
      return
    }

    let name = notification as String
    if name == (kAXUIElementDestroyedNotification as String) {
      DispatchQueue.main.async { [weak self] in
        guard let self,
          let current = self.pinnedWindowSnapshot(),
          CFEqual(current.element, element)
        else {
          return
        }

        self.setPinnedWindow(nil)
        self.setFeedback("The pinned window closed; the pin was cleared.")
      }
      return
    }

    if name == (kAXTitleChangedNotification as String) {
      requestPinnedWindowTitleRefresh(expectedElement: element)
      return
    }

    if name == (kAXFocusedWindowChangedNotification as String)
      || name == (kAXMainWindowChangedNotification as String)
    {
      requestImmediateRaise()
    }
  }

  // MARK: - Workspace tracking

  private func startWorkspaceTracking() {
    updateLastExternalApplication(from: NSWorkspace.shared.frontmostApplication)

    let center = NSWorkspace.shared.notificationCenter
    let activationObserver = center.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      let application =
        notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      self?.updateLastExternalApplication(from: application)
      self?.requestImmediateRaise()
    }

    let terminationObserver = center.addObserver(
      forName: NSWorkspace.didTerminateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let self,
        let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
          as? NSRunningApplication,
        let pinned = self.pinnedWindowSnapshot(),
        application.isEqual(pinned.runningApplication)
      else {
        return
      }
      self.setPinnedWindow(nil)
      self.setFeedback("The pinned application closed; the pin was cleared.")
    }

    workspaceObservers = [activationObserver, terminationObserver]
  }

  private func updateLastExternalApplication(from application: NSRunningApplication?) {
    guard let application,
      application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
      !application.isTerminated
    else {
      return
    }
    lastExternalApplication = application
  }

  // MARK: - Permission and commands

  private func ensureAccessibilityPermission(prompt: Bool) -> Bool {
    if AXIsProcessTrusted() { return true }
    guard prompt else { return false }

    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options = [promptKey: true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  @objc private func openAccessibilitySettings() {
    let settingsURLs = [
      "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
      "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
    ]

    for rawValue in settingsURLs {
      if let url = URL(string: rawValue), NSWorkspace.shared.open(url) {
        setFeedback("Opened Accessibility settings.")
        return
      }
    }

    setFeedback("Could not open Accessibility settings automatically.", isError: true)
  }

  @objc private func openScreenRecordingSettings() {
    // Prompt once via the system API (harmless if already granted), then open the pane.
    _ = CGRequestScreenCaptureAccess()

    let settingsURLs = [
      "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
      "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
    ]

    for rawValue in settingsURLs {
      if let url = URL(string: rawValue), NSWorkspace.shared.open(url) {
        setFeedback("Opened Screen Recording settings.")
        return
      }
    }

    setFeedback("Could not open Screen Recording settings automatically.", isError: true)
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }

  private func description(for error: AXError) -> String {
    switch error {
    case .success:
      return "success"
    case .apiDisabled:
      return "Accessibility permission is disabled"
    case .actionUnsupported:
      return "the window does not support the raise action"
    case .invalidUIElement:
      return "the window is no longer valid"
    case .cannotComplete:
      return "the application did not respond"
    case .notImplemented:
      return "the application does not implement this action"
    case .illegalArgument:
      return "macOS rejected the window reference"
    default:
      return "Accessibility error \(error.rawValue)"
    }
  }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
