// 고객 여정 지도용 실제 화면 촬영 도우미 (깨끗한 Mac CI 전용). 사람 손처럼 마우스·키 입력을 화면 서버에 보낸다.
//   journey_input wins                 화면에 있는 창 (주인 · 층 · id · 왼쪽 위 기준 테두리)
//   journey_input click X Y            왼쪽 클릭
//   journey_input key NAME [cmd|opt]   키 하나 (return escape comma space down up tab)
//   journey_input opt down|up          ⌥ 누르고 있기 / 떼기
//   journey_input rclick X Y           오른쪽 클릭
//   journey_input move X Y             마우스만 옮기기
import CoreGraphics
import Foundation

func windows() -> [[String: Any]] {
    (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
}
func bounds(_ w: [String: Any]) -> CGRect {
    guard let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) else { return .zero }
    return r
}
func mouse(_ type: CGEventType, _ p: CGPoint) {
    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
    e?.setIntegerValueField(.mouseEventClickState, value: 1)
    e?.post(tap: .cghidEventTap); usleep(30_000)
}
let codes: [String: CGKeyCode] = ["return": 36, "escape": 53, "comma": 43, "space": 49, "down": 125, "up": 126, "tab": 48, "left": 123, "right": 124, "w": 13]
func key(_ code: CGKeyCode, _ flags: CGEventFlags) {
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        e?.flags = flags; e?.post(tap: .cghidEventTap); usleep(40_000)
    }
}
let a = CommandLine.arguments
switch a.count > 1 ? a[1] : "" {
case "wins":
    for w in windows() {
        let r = bounds(w)
        print("\(w[kCGWindowOwnerName as String] as? String ?? "?") · 층 \(w[kCGWindowLayer as String] as? Int ?? 0) · id \(w[kCGWindowNumber as String] as? Int ?? 0) · \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))")
    }
case "click":
    let p = CGPoint(x: Double(a[2])!, y: Double(a[3])!)
    mouse(.mouseMoved, p); usleep(120_000); mouse(.leftMouseDown, p); usleep(80_000); mouse(.leftMouseUp, p)
case "rclick":
    let p = CGPoint(x: Double(a[2])!, y: Double(a[3])!)
    for (t, u) in [(CGEventType.rightMouseDown, CGEventType.rightMouseUp)] {
        mouse(.mouseMoved, p); usleep(120_000)
        let d = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .right); d?.post(tap: .cghidEventTap); usleep(80_000)
        let e = CGEvent(mouseEventSource: nil, mouseType: u, mouseCursorPosition: p, mouseButton: .right); e?.post(tap: .cghidEventTap)
    }
case "move":
    mouse(.mouseMoved, CGPoint(x: Double(a[2])!, y: Double(a[3])!))
case "key":
    var f: CGEventFlags = []
    if a.count > 3 { if a[3].contains("cmd") { f.insert(.maskCommand) }; if a[3].contains("opt") { f.insert(.maskAlternate) } }
    key(codes[a[2]] ?? 36, f)
case "opt":
    let e = CGEvent(keyboardEventSource: nil, virtualKey: 58, keyDown: a[2] == "down")
    e?.type = .flagsChanged
    e?.flags = a[2] == "down" ? .maskAlternate : []
    e?.post(tap: .cghidEventTap)
default:
    print("사용: journey_input wins|click X Y|move X Y|key NAME [cmd|opt]|opt down|up")
}
