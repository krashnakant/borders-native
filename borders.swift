// Native take on JankyBorders: draws a border around the focused window.
// Tracks focus/move/resize via the Accessibility API (needs Accessibility permission)
// and draws with a click-through overlay NSWindow + CAShapeLayer.
// Private bits (same as JankyBorders/yabai): _AXUIElementGetWindow for the window id,
// SkyLight's SLSWindowIteratorGetCornerRadii for the real per-window corner radius.
//
// Usage (same key=value style as JankyBorders):
//   borders active_color="glow(0xffd61515)" width=3.0 style=round [radius=12 to force]
import AppKit
import ApplicationServices

// MARK: config

var width: CGFloat = 5
var radiusOverride: CGFloat? // nil: ask SkyLight per window
var square = false
var color = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
var glow = false

func parseColor(_ raw: String) -> (CGColor, Bool)? {
  var s = raw, isGlow = false
  if s.hasPrefix("glow("), s.hasSuffix(")") { isGlow = true; s = String(s.dropFirst(5).dropLast()) }
  guard s.hasPrefix("0x"), let v = UInt32(s.dropFirst(2), radix: 16) else { return nil }
  let c = { (shift: UInt32) in CGFloat((v >> shift) & 0xff) / 255 }
  return (CGColor(srgbRed: c(16), green: c(8), blue: c(0), alpha: c(24)), isGlow)
}

for arg in CommandLine.arguments.dropFirst() {
  let kv = arg.split(separator: "=", maxSplits: 1).map(String.init)
  guard kv.count == 2 else { continue }
  switch kv[0] {
  case "width": width = CGFloat(Double(kv[1]) ?? Double(width))
  case "radius": radiusOverride = Double(kv[1]).map { CGFloat($0) }
  case "style": square = kv[1] == "square"
  case "active_color":
    if let (c, g) = parseColor(kv[1]) { color = c; glow = g } else { print("bad color: \(kv[1])") }
  default: print("ignored option: \(kv[0])") // inactive_color, hidpi, blacklist, ... not implemented
  }
}

// MARK: overlay

let pad = width + (glow ? width * 4 : 0)
let overlay = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
overlay.isOpaque = false
overlay.backgroundColor = .clear
overlay.hasShadow = false
overlay.ignoresMouseEvents = true
overlay.isReleasedWhenClosed = false
overlay.animationBehavior = .none // no system fade/zoom when ordered in after a hide
overlay.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

let shape = CAShapeLayer()
shape.fillColor = nil
shape.strokeColor = color
shape.lineWidth = width
if glow {
  shape.shadowColor = color
  shape.shadowOpacity = 1
  shape.shadowRadius = width * 2
  shape.shadowOffset = .zero
}
// Layer-hosting view (layer set before wantsLayer): AppKit never swaps it out, unlike a
// layer-backed view whose layer can get rebuilt on power-mode/display changes, dropping sublayers.
let host = NSView()
host.layer = shape
host.wantsLayer = true
overlay.contentView = host

var lastFrame = CGRect.null

func show(_ axFrame: CGRect, wid: CGWindowID, radius: CGFloat, reorder: Bool = true) {
  defer { if reorder { overlay.order(.above, relativeTo: Int(wid)) } } // after frame + ring are in place
  guard axFrame != lastFrame else { return } // moves arrive twice (app + window observers)
  let sameSize = axFrame.size == lastFrame.size
  lastFrame = axFrame
  // AX uses top-left origin on the primary screen; Cocoa uses bottom-left.
  let primaryH = NSScreen.screens.first?.frame.height ?? 0
  let target = CGRect(x: axFrame.minX, y: primaryH - axFrame.maxY, width: axFrame.width, height: axFrame.height)
  if sameSize { return overlay.setFrameOrigin(CGPoint(x: target.minX - pad, y: target.minY - pad)) } // drag: no redraw
  // Focus switch: the window server applies the new frame before the new ring renders, so for a frame
  // the old ring shows stretched into the new window. Hide while resizing, show once the ring is committed.
  if reorder { overlay.orderOut(nil) }
  defer { if reorder { CATransaction.flush() } }
  CATransaction.begin()
  CATransaction.setDisableActions(true)
  overlay.setFrame(target.insetBy(dx: -pad, dy: -pad), display: false)
  let ring = CGRect(origin: .zero, size: target.size).offsetBy(dx: pad, dy: pad).insetBy(dx: -width / 2, dy: -width / 2)
  let r = radius == 0 ? 0 : radius + width / 2
  let path = CGPath(roundedRect: ring, cornerWidth: r, cornerHeight: r, transform: nil)
  shape.path = path
  // explicit shadowPath: no offscreen pass to derive the glow from the rendered stroke
  if glow { shape.shadowPath = path.copy(strokingWithWidth: width, lineCap: .butt, lineJoin: .miter, miterLimit: 10) }
  CATransaction.commit()
}

func hide() { overlay.orderOut(nil); lastFrame = .null }

// MARK: window id + corner radius

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ el: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
func skyFn<T>(_ name: String, _: T.Type) -> T? { dlsym(sky, name).map { unsafeBitCast($0, to: T.self) } }
let SLSMainConnectionID = skyFn("SLSMainConnectionID", (@convention(c) () -> Int32).self)
let SLSWindowQueryWindows = skyFn("SLSWindowQueryWindows", (@convention(c) (Int32, CFArray, UInt32) -> Unmanaged<CFTypeRef>?).self)
let SLSWindowQueryResultCopyWindows = skyFn("SLSWindowQueryResultCopyWindows", (@convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?).self)
let SLSWindowIteratorAdvance = skyFn("SLSWindowIteratorAdvance", (@convention(c) (CFTypeRef) -> Bool).self)
let SLSWindowIteratorGetCornerRadii = skyFn("SLSWindowIteratorGetCornerRadii", (@convention(c) (CFTypeRef) -> Unmanaged<CFArray>?).self)

func cornerRadius(_ wid: CGWindowID) -> CGFloat? {
  guard let cid = SLSMainConnectionID?(), let query = SLSWindowQueryWindows, let copy = SLSWindowQueryResultCopyWindows,
        let advance = SLSWindowIteratorAdvance, let radii = SLSWindowIteratorGetCornerRadii,
        let q = query(cid, [NSNumber(value: wid)] as CFArray, 0)?.takeRetainedValue(),
        let it = copy(q)?.takeRetainedValue(), advance(it),
        let r = (radii(it)?.takeRetainedValue() as? [NSNumber])?.first?.doubleValue, r > 0
  else { return nil }
  return CGFloat(r)
}

// Window-server move/resize events (what JankyBorders uses): fire every frame while dragging,
// unlike AX moved notifications, which apps post late, coalesced, or only on mouse-up.
typealias NotifyProc = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void
let SLSRegisterNotifyProc = skyFn("SLSRegisterNotifyProc", (@convention(c) (NotifyProc, UInt32, UnsafeMutableRawPointer?) -> Int32).self)
let SLSRequestNotificationsForWindows = skyFn("SLSRequestNotificationsForWindows", (@convention(c) (Int32, UnsafePointer<UInt32>, Int32) -> Int32).self)
let SLSGetWindowBounds = skyFn("SLSGetWindowBounds", (@convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> Int32).self)
let kWindowMoved: UInt32 = 806, kWindowResized: UInt32 = 807
var wsEvents = false // true once window-server move/resize handlers are registered

// Window-server bounds use the same top-left global coordinates as AX.
func wsBounds(_ wid: CGWindowID) -> CGRect? {
  guard let get = SLSGetWindowBounds, let cid = SLSMainConnectionID?() else { return nil }
  var r = CGRect.zero
  return get(cid, wid, &r) == 0 && r.width > 0 ? r : nil
}

func watchWindowServer(_ wid: CGWindowID) {
  guard wsEvents, let request = SLSRequestNotificationsForWindows, let cid = SLSMainConnectionID?() else { return }
  var w = wid
  _ = request(cid, &w, 1) // replaces the previous window
}

let wsCallback: NotifyProc = { _, data, _, _ in
  guard let wid = data?.load(as: UInt32.self) else { return }
  let move = {
    guard wid == trackedWid else { return }
    guard overlay.isVisible, let r = wsBounds(wid) else { return update() } // hidden by a transient failure: re-check
    show(r, wid: wid, radius: trackedRadius, reorder: false)
  }
  if Thread.isMainThread { move() } else { DispatchQueue.main.async(execute: move) }
}

func onScreen(_ wid: CGWindowID) -> Bool {
  let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, wid) as? [[String: Any]]
  return info?.first?[kCGWindowIsOnscreen as String] as? Bool ?? false
}

// MARK: accessibility tracking

var observers: [pid_t: AXObserver] = [:] // one per running app, so activation events arrive straight from the app
var frontPid: pid_t = 0
var trackedPid: pid_t = 0
var trackedWin: AXUIElement?
var trackedWid: CGWindowID = 0
var trackedRadius: CGFloat = 9
var observedWin: AXUIElement? // holds windowNotes; separate from trackedWin so dropping focus never leaks registrations
var observedPid: pid_t = 0
let appNotes = [kAXApplicationActivatedNotification, kAXFocusedWindowChangedNotification, kAXWindowMovedNotification,
                kAXWindowResizedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                kAXApplicationHiddenNotification]
let windowNotes = [kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification,
                   kAXWindowMiniaturizedNotification]

func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
  var v: CFTypeRef?
  guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
  return v as? T
}

func frame(of win: AXUIElement) -> CGRect? {
  guard let p: AXValue = attr(win, kAXPositionAttribute), let s: AXValue = attr(win, kAXSizeAttribute) else { return nil }
  var pt = CGPoint.zero, sz = CGSize.zero
  AXValueGetValue(p, .cgPoint, &pt)
  AXValueGetValue(s, .cgSize, &sz)
  return CGRect(origin: pt, size: sz)
}

func update() {
  guard frontPid != 0, let win: AXUIElement = attr(AXUIElementCreateApplication(frontPid), kAXFocusedWindowAttribute),
        let f = frame(of: win), f.width > 0,
        (attr(win, kAXMinimizedAttribute) as Bool?) != true,
        (attr(win, "AXFullScreen") as Bool?) != true,
        (attr(win, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole
  else { return hide() }

  // Re-subscribe after drawing: unsubscribing from a frozen old app blocks for the AX timeout
  // per call (~1.2s for all four), which used to hold back the new border.
  defer {
    if observedWin == nil || !CFEqual(observedWin, win) {
      for n in windowNotes {
        if let old = observedWin, let o = observers[observedPid] { AXObserverRemoveNotification(o, old, n as CFString) }
        if let o = observers[frontPid] { AXObserverAddNotification(o, win, n as CFString, nil) }
      }
      observedWin = win
      observedPid = frontPid
    }
  }
  if trackedWin == nil || !CFEqual(trackedWin, win) {
    trackedWin = win
    trackedPid = frontPid
    lastFrame = .null // same-frame window (tabs) may still need a new radius
    trackedWid = 0
    _ = _AXUIElementGetWindow(win, &trackedWid)
    trackedRadius = square ? 0 : radiusOverride ?? cornerRadius(trackedWid) ?? 9
    // focused window on another space: don't draw it on this one
    if trackedWid != 0, !onScreen(trackedWid) { trackedWid = 0 }
    if trackedWid != 0 { watchWindowServer(trackedWid) }
  }
  guard trackedWid != 0 else { trackedWin = nil; return hide() } // re-resolve next event
  show(wsBounds(trackedWid) ?? f, wid: trackedWid, radius: trackedRadius) // AX frame can be stale mid-drag
}

let axCallback: AXObserverCallback = { _, el, note, _ in
  var pid: pid_t = 0
  AXUIElementGetPid(el, &pid)
  switch note as String {
  case kAXApplicationActivatedNotification: frontPid = pid
  case kAXMovedNotification, kAXResizedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification:
    // hot path while dragging: only the tracked window's frame, no focus/state re-query, no restack
    guard let w = trackedWin, CFEqual(w, el) else { return }
    // fallback if window-server events stop; read bounds from the window server anyway, AX frames lag mid-drag
    guard overlay.isVisible, let f = wsBounds(trackedWid) ?? frame(of: w) else { return update() }
    return show(f, wid: trackedWid, radius: trackedRadius, reorder: false)
  case kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification:
    guard let w = trackedWin, CFEqual(w, el) else { return } // some other window
    dropBorder()
    return
  case kAXApplicationHiddenNotification:
    guard pid == frontPid else { return }
    dropBorder()
    return
  default: guard pid == frontPid else { return } // background app activity
  }
  update()
}

// Tracked window went away: hide now, then re-query once the app/system has moved focus on.
func dropBorder() {
  hide()
  trackedWin = nil
  DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: update)
}

func observe(_ a: NSRunningApplication) {
  let pid = a.processIdentifier
  guard a.activationPolicy == .regular, pid != getpid(), observers[pid] == nil else { return }
  var o: AXObserver?
  guard AXObserverCreate(pid, axCallback, &o) == .success, let o else { return }
  let el = AXUIElementCreateApplication(pid)
  for n in appNotes { AXObserverAddNotification(o, el, n as CFString, nil) }
  CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .commonModes)
  observers[pid] = o
}

// MARK: main

// Prompt once, then wait. The trust answer is cached per process, so re-exec ourselves
// (same pid, no new prompt) to re-check; exiting would make launchd respawn and re-prompt.
if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): getenv("BORDERS_PROMPTED") == nil] as CFDictionary) {
  if getenv("BORDERS_PROMPTED") == nil {
    print("Waiting for Accessibility permission (System Settings > Privacy & Security > Accessibility)...")
  }
  setenv("BORDERS_PROMPTED", "1", 1)
  sleep(2)
  execv(CommandLine.arguments[0].hasPrefix("/") ? CommandLine.arguments[0] : Bundle.main.executablePath!, CommandLine.unsafeArgv)
  exit(1)
}

// Default AX timeout is ~6s; a closing/hung app would freeze the border that long.
AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.3)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let ws = NSWorkspace.shared.notificationCenter
func running(_ n: Notification) -> NSRunningApplication? { n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { n in running(n).map(observe) }
ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { n in
  guard let pid = running(n)?.processIdentifier, let o = observers.removeValue(forKey: pid) else { return }
  CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .commonModes)
  if pid == trackedPid { trackedPid = 0; dropBorder() }
}
// Fallback for apps whose AX activation event never came (slower, arrives after the switch).
ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
  guard let a = running(n), a.processIdentifier != frontPid else { return }
  observe(a)
  frontPid = a.processIdentifier
  update()
}
ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
  trackedWin = nil // window may sit on another space now; re-resolve
  update()
}
NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
  trackedWin = nil // display layout changed: same AX frame can map to a new Cocoa frame
  update()
}
NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
  DispatchQueue.main.async { trackedWin = nil; update() } // posted off-main; redraw from scratch
}
ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in trackedWin = nil; update() }
ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in trackedWin = nil; update() }

if let register = SLSRegisterNotifyProc {
  wsEvents = register(wsCallback, kWindowMoved, nil) == 0 && register(wsCallback, kWindowResized, nil) == 0
}
NSWorkspace.shared.runningApplications.forEach(observe)
frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
update()
app.run()
