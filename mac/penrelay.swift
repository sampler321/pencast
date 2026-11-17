// PenRelay (Mac): receives Surface pen packets over UDP and replays them as a tablet pen (Wacom-style CGEvents),
// so apps like Illustrator get pressure, tilt and proximity. Packet: "x y p tiltX tiltY flags" with x,y in 0..1 of the
// Surface screen, p 0..1, tilt -1..1, flags bit0 in-range, bit1 tip down, bit2 barrel, bit3 eraser.
// The Surface shows the Mac main display via Moonlight, letterboxed: surfaceAspect sets that mapping.
import Foundation
import AppKit
import CoreGraphics
setvbuf(stdout, nil, _IOLBF, 0)
let port: UInt16 = 47555, surfaceAspect = 1.5
let src = CGEventSource(stateID: .hidSystemState)
let dev: Int64 = 7
var inRange = false, tip = false, lastX = 0.0, lastY = 0.0
func screenPoint(_ nx: Double, _ ny: Double) -> CGPoint {
    let b = CGDisplayBounds(CGMainDisplayID()); let macAspect = Double(b.width / b.height)
    var x = nx, y = ny
    if macAspect > surfaceAspect { let h = surfaceAspect / macAspect; y = (ny - (1 - h) / 2) / h }   // bars top/bottom
    else { let w = macAspect / surfaceAspect; x = (nx - (1 - w) / 2) / w }                            // bars left/right
    return CGPoint(x: Double(b.minX) + min(max(x, 0), 1) * Double(b.width), y: Double(b.minY) + min(max(y, 0), 1) * Double(b.height))
}
func prox(_ enter: Bool, _ p: CGPoint, eraser: Bool) {
    guard let e = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left) else { return }
    e.type = .tabletProximity
    e.setIntegerValueField(.mouseEventSubtype, value: 2)
    e.setIntegerValueField(.tabletProximityEventVendorID, value: 0x056A)
    e.setIntegerValueField(.tabletProximityEventTabletID, value: 1)
    e.setIntegerValueField(.tabletProximityEventPointerID, value: 1)
    e.setIntegerValueField(.tabletProximityEventDeviceID, value: dev)
    e.setIntegerValueField(.tabletProximityEventSystemTabletID, value: 1)
    e.setIntegerValueField(.tabletProximityEventVendorPointerType, value: 0x0802)
    e.setIntegerValueField(.tabletProximityEventVendorPointerSerialNumber, value: 1)
    e.setIntegerValueField(.tabletProximityEventVendorUniqueID, value: 1)
    e.setIntegerValueField(.tabletProximityEventCapabilityMask, value: 0x0547)
    e.setIntegerValueField(.tabletProximityEventPointerType, value: eraser ? 3 : 1)
    e.setIntegerValueField(.tabletProximityEventEnterProximity, value: enter ? 1 : 0)
    e.post(tap: .cghidEventTap)
}
// pen inputs from the InkStudio rail (PluginData/pen-inputs.json): what the pen is allowed to send
struct Inputs { var pressure = true, tilt = true, barrel = true, eraser = true }
var inputs = Inputs(); var inputsAt = Date.distantPast; var tiltSeen = 0.0; var capsAt = Date.distantPast
let pluginData = NSHomeDirectory() + "/Library/Application Support/Adobe/UXP/PluginsStorage/PHSP/27/External/inkstudio.photoshop/PluginData/"
func readInputs() {
    if Date().timeIntervalSince(inputsAt) < 0.5 { return }
    inputsAt = Date()
    if let d = FileManager.default.contents(atPath: pluginData + "pen-inputs.json"), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
        func b(_ k: String) -> Bool { (j[k] as? Bool) ?? true }
        inputs = Inputs(pressure: b("pressure"), tilt: b("tilt"), barrel: b("barrel"), eraser: b("eraser"))
    } else { inputs = Inputs() }
    if Date().timeIntervalSince(capsAt) > 5 {   // tell the rail what this pen actually sends
        capsAt = Date()
        let caps = "{\"pressure\": true, \"tilt\": \(tiltSeen > 0.02), \"rotation\": false, \"wheel\": false, \"barrel\": true, \"eraser\": true}"
        try? caps.write(toFile: pluginData + "pen-caps.json", atomically: true, encoding: .utf8)
    }
}
// per-brush pressure curve from the InkStudio Photoshop panel (PluginData/pressure-curve.json), re-read twice a second
struct Curve { var inLo = 0.0, inHi = 100.0, outLo = 0.0, outHi = 100.0, bend = 0.0 }
var curve = Curve(); var curveAt = Date.distantPast
let curvePath = NSHomeDirectory() + "/Library/Application Support/Adobe/UXP/PluginsStorage/PHSP/27/External/inkstudio.photoshop/PluginData/pressure-curve.json"
func shaped(_ p: Double) -> Double {
    if Date().timeIntervalSince(curveAt) > 0.5 {
        curveAt = Date()
        if let d = FileManager.default.contents(atPath: curvePath), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            func n(_ k: String, _ def: Double) -> Double { (j[k] as? NSNumber)?.doubleValue ?? def }
            curve = Curve(inLo: n("inLo", 0), inHi: n("inHi", 100), outLo: n("outLo", 0), outHi: n("outHi", 100), bend: n("bend", 0))
        } else { curve = Curve() }
    }
    if p <= 0 || frontIsIllustrator() { return p }
    let t = max(0, min(1, (p * 100 - curve.inLo) / max(1, curve.inHi - curve.inLo)))
    let g = pow(2, -curve.bend / 25)
    return max(0.001, (curve.outLo + (curve.outHi - curve.outLo) * pow(t, g)) / 100)
}
// optional Illustrator integration: InkStudio for Illustrator's host script (set PENRELAY_AI_HOST to its host.jsx)
let illustratorHost = ProcessInfo.processInfo.environment["PENRELAY_AI_HOST"] ?? (NSHomeDirectory() + "/inkstudio-illustrator/jsx/host.jsx")
// barrel button held = Option held: in Photoshop a tap then picks the colour under the pen (Procreate's eyedropper)
var barrel = false
func setBarrel(_ on: Bool) {
    if on == barrel { return }
    barrel = on
    if frontIsIllustrator() { return }
    let e = CGEvent(keyboardEventSource: src, virtualKey: 58, keyDown: on)   // 58 = left Option
    e?.type = .flagsChanged; e?.flags = on ? .maskAlternate : CGEventFlags(rawValue: 0); e?.post(tap: .cghidEventTap)
}
func pen(_ t: CGEventType, _ p: CGPoint, _ pr: Double, _ tx: Double, _ ty: Double, _ down: Bool) {
    guard let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left) else { return }
    e.flags = (barrel && !frontIsIllustrator()) ? .maskAlternate : CGEventFlags(rawValue: 0)   // never inherit a modifier
    e.setIntegerValueField(.mouseEventSubtype, value: 1)
    e.setDoubleValueField(.mouseEventPressure, value: pr)
    e.setDoubleValueField(.tabletEventPointPressure, value: pr)
    e.setIntegerValueField(.tabletEventPointButtons, value: down ? 1 : 0)
    e.setIntegerValueField(.tabletEventDeviceID, value: dev)
    e.setDoubleValueField(.tabletEventTiltX, value: tx); e.setDoubleValueField(.tabletEventTiltY, value: ty)
    e.setIntegerValueField(.tabletEventPointX, value: Int64(p.x * 10)); e.setIntegerValueField(.tabletEventPointY, value: Int64(p.y * 10))
    e.post(tap: .cghidEventTap)
}
// two-finger pan (scroll) and pinch (Option+scroll zoom at the fingers); quick 2/3-finger taps = undo/redo
var penSeen = Date.distantPast
var pinchAcc = 0.0
var tN = 0, tX = 0.0, tY = 0.0, tD = 0.0, tZoom = 0.0, tStart = Date(), tMax = 0, tMoved = 0.0
let zsrc = CGEventSource(stateID: .privateState)   // own source: the Option flag of zoom events must not leak into pan
func scroll(_ dy: Int32, _ dx: Int32, option: Bool = false, at p: CGPoint? = nil) {
    if let p = p, !option { CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap) }
    guard let e = CGEvent(scrollWheelEvent2Source: option ? zsrc : src, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
    e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    e.flags = option ? .maskAlternate : CGEventFlags(rawValue: 0)
    if let p = p { e.location = p }
    e.post(tap: .cghidEventTap)
}
// which app gets the gestures: Illustrator needs scripted zoom/undo, Photoshop uses its own Option+scroll zoom and Cmd+Z
func frontIsIllustrator() -> Bool { return NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.hasPrefix("com.adobe.illustrator") ?? false }
// smooth pinch: Illustrator's own zoom set by script, proportional to the finger spread, ~15 updates a second
let zoomLock = NSLock(); var pendingZoom = 0.0
Thread {
    while true {
        usleep(66000)
        zoomLock.lock(); let z = pendingZoom; pendingZoom = 0; zoomLock.unlock()
        if abs(z) < 0.004 { continue }
        let js = "var v=app.activeDocument.activeView; v.zoom=Math.max(0.05,Math.min(640,v.zoom*\(exp(z))));"
        var err: NSDictionary?
        NSAppleScript(source: "tell application \"Adobe Illustrator\" to do javascript \"" + js + "\"")?.executeAndReturnError(&err)
    }
}.start()
// pen-up: pressure along the stroke as "position 0..1, pressure" pairs, ~48 even steps, to InkStudio (pressure -> opacity)
func sendPressure(_ log: [(CGPoint, Double)]) {
    guard log.count > 2 else { return }
    var acc = [0.0]; for i in 1..<log.count { acc.append(acc[i - 1] + hypot(Double(log[i].0.x - log[i - 1].0.x), Double(log[i].0.y - log[i - 1].0.y))) }
    let total = acc.last!; guard total > 2 else { return }
    var out: [String] = []; var j = 0; let n = 48
    for k in 0...n {
        let s = total * Double(k) / Double(n)
        while j < log.count - 2 && acc[j + 1] < s { j += 1 }
        out.append(String(format: "%.4f,%.3f", s / total, log[j].1))
    }
    let samples = out.joined(separator: ";")
    if frontIsIllustrator() { DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { aiScriptQuiet("inkPressureOpacity('" + samples + "')") } }
}
func aiScriptQuiet(_ call: String) {
    var err: NSDictionary?
    let js = "$.evalFile('" + illustratorHost + "'); " + call
    NSAppleScript(source: "tell application \"Adobe Illustrator\" to do javascript \"" + js + "\"")?.executeAndReturnError(&err)
}
func aiScript(_ call: String) {   // InkStudio's undo also removes the opacity step the rail adds after a stroke
    DispatchQueue.global().async {
        var err: NSDictionary?
        let js = "$.evalFile('" + illustratorHost + "'); " + call
        NSAppleScript(source: "tell application \"Adobe Illustrator\" to do javascript \"" + js + "\"")?.executeAndReturnError(&err)
        if err != nil { key(6, .maskCommand) }
    }
}
// shortcut with real modifier presses and releases: a modifier flag left behind (Cmd!) turns every following pen stroke
// into Photoshop's Move tool, so press and release Cmd/Shift explicitly around the key
let ksrc = CGEventSource(stateID: .privateState)
func key(_ code: CGKeyCode, _ flags: CGEventFlags) {
    var mods: [(CGKeyCode, CGEventFlags)] = []
    if flags.contains(.maskCommand) { mods.append((55, .maskCommand)) }
    if flags.contains(.maskShift) { mods.append((56, .maskShift)) }
    var held = CGEventFlags(rawValue: 0)
    for (k, f) in mods { held.insert(f); let e = CGEvent(keyboardEventSource: ksrc, virtualKey: k, keyDown: true); e?.type = .flagsChanged; e?.flags = held; e?.post(tap: .cghidEventTap) }
    for down in [true, false] { let e = CGEvent(keyboardEventSource: ksrc, virtualKey: code, keyDown: down); e?.flags = held; e?.post(tap: .cghidEventTap) }
    for (k, f) in mods.reversed() { held.remove(f); let e = CGEvent(keyboardEventSource: ksrc, virtualKey: k, keyDown: false); e?.type = .flagsChanged; e?.flags = held; e?.post(tap: .cghidEventTap) }
}
func touch(_ f: [Double]) {
    let n = Int(f[0]), b = CGDisplayBounds(CGMainDisplayID())
    if n > 0 && tN == 0 { tStart = Date(); tMax = 0; tMoved = 0 }
    tMax = max(tMax, n)
    if inRange || Date().timeIntervalSince(penSeen) < 0.4 { tN = 0; return }   // palm while drawing: ignore touch
    if (n == 1 || n == 2) && tN == n {
        let dx = (f[1] - tX) * Double(b.width), dy = (f[2] - tY) * Double(b.height); tMoved += abs(dx) + abs(dy)
        if abs(dx) + abs(dy) > 0.5 { scroll(Int32(-dy.rounded()), Int32(-dx.rounded()), at: screenPoint(f[1], f[2])) }   // scroll goes to the window under the point
        if n == 2 && tD > 0.02 && f[3] > 0.02 {
            tZoom += log(f[3] / tD); tMoved += abs(log(f[3] / tD)) * 400
            if frontIsIllustrator() { zoomLock.lock(); pendingZoom += log(f[3] / tD); zoomLock.unlock() }
            else {   // Photoshop: its own Zoom In / Zoom Out (Cmd+= / Cmd+-) per step of finger spread
                pinchAcc += log(f[3] / tD)
                let step = 0.16
                while pinchAcc >= step { key(24, .maskCommand); pinchAcc -= step }    // 24 = '=' : zoom in
                while pinchAcc <= -step { key(27, .maskCommand); pinchAcc += step }   // 27 = '-' : zoom out
            }
        }
    }
    if n != tN { tZoom = 0; pinchAcc = 0 }
    if n == 0 && tN > 0 {
        let ms = Date().timeIntervalSince(tStart) * 1000
        if ms < 300 && tMoved < 25 { if tMax == 2 { if frontIsIllustrator() { aiScript("inkUndo()") } else { key(6, .maskCommand) } } else if tMax == 3 { key(6, [.maskCommand, .maskShift]) } }   // 6 = Z
    }
    tN = n; if f.count > 3 { tX = f[1]; tY = f[2]; tD = f[3] }
}
// stroke filter: light smoothing, no sub-pixel moves, and the last few samples before lift-off are held back and
// dropped if they hook backwards (pen lift jitter folds art brushes into spikes)
var downAt = CGPoint.zero
var strokeLog: [(CGPoint, Double)] = []
var sx = 0.0, sy = 0.0, held: [(CGPoint, Double, Double, Double)] = [], lastSent = CGPoint.zero
func sendDrag(_ q: (CGPoint, Double, Double, Double)) {
    if hypot(q.0.x - lastSent.x, q.0.y - lastSent.y) < 0.6 { return }
    pen(.leftMouseDragged, q.0, q.1, q.2, q.3, true); lastSent = q.0; strokeLog.append((q.0, q.1))
}
func handle(_ s: String) {
    if s.hasPrefix("T ") { touch(s.dropFirst(2).split(separator: " ").compactMap { Double($0) }); return }
    let f0 = s.split(separator: " ").compactMap { Double($0) }; guard f0.count >= 6 else { return }
    readInputs()
    var f = f0
    tiltSeen = max(tiltSeen, abs(f[3]), abs(f[4]))
    if !inputs.tilt { f[3] = 0; f[4] = 0 }
    if !inputs.barrel { f[5] = Double(Int(f[5]) & ~4) }
    if !inputs.eraser { f[5] = Double(Int(f[5]) & ~8) }
    let raw = screenPoint(f[0], f[1]), pr = (inputs.pressure || frontIsIllustrator()) ? shaped(f[2]) : (f[2] > 0 ? 1.0 : 0), flags = Int(f[5])
    let nowIn = flags & 1 != 0 || flags & 2 != 0, nowTip = flags & 2 != 0, eraser = flags & 8 != 0
    setBarrel(nowIn && flags & 4 != 0)
    if nowTip && tip { sx += (Double(raw.x) - sx) * 0.55; sy += (Double(raw.y) - sy) * 0.55 } else { sx = Double(raw.x); sy = Double(raw.y) }
    let p = CGPoint(x: sx, y: sy)
    if nowIn && !inRange { prox(true, p, eraser: eraser) }
    if nowTip && !tip { held = []; lastSent = p; downAt = p; strokeLog = [(p, max(pr, 0.01))]; pen(.leftMouseDown, p, max(pr, 0.01), f[3], f[4], true) }
    else if nowTip {
        // start-of-stroke jitter: ignore samples until the pen has really left the down point
        if lastSent == downAt && hypot(p.x - downAt.x, p.y - downAt.y) < 3 { return }
        held.append((p, max(pr, 0.01), f[3], f[4]))
        if held.count > 3 { sendDrag(held.removeFirst()) }
    } else if tip {
        // lift-off: keep held samples only while they continue the stroke's direction
        var end = lastSent
        if let first = held.first { let dx0 = first.0.x - lastSent.x, dy0 = first.0.y - lastSent.y
            for q in held { let dx = q.0.x - end.x, dy = q.0.y - end.y
                if dx * dx0 + dy * dy0 < 0 { break }       // turned back: the hook starts here
                sendDrag(q); end = q.0 } }
        held = []; pen(.leftMouseUp, end, 0, f[3], f[4], false)
        sendPressure(strokeLog)
    }
    else if nowIn { pen(.mouseMoved, raw, 0, f[3], f[4], false) }
    if !nowIn && inRange { prox(false, raw, eraser: eraser) }
    if nowIn { penSeen = Date() }
    inRange = nowIn; tip = nowTip
}
let fd = socket(AF_INET, SOCK_DGRAM, 0)
var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = port.bigEndian; addr.sin_addr.s_addr = INADDR_ANY
_ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
print("PenRelay listening on udp \(port)")
var buf = [UInt8](repeating: 0, count: 512); var n = 0
while true {
    let r = recv(fd, &buf, buf.count, 0); if r <= 0 { continue }
    handle(String(decoding: buf[0..<r], as: UTF8.self)); n += 1
    if n % 500 == 1 { print("packets \(n)") }
}
