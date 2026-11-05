// 오브 끌어 옮기기 재현용 도우미 (깨끗한 Mac CI 전용). 사람 손처럼 실제 마우스·키 입력을 화면 서버에 보낸다.
//   orb_mouse preflight          입력 보내기·화면 찍기 권한
//   orb_mouse wins               화면에 있는 창 (주인 · 층 · 왼쪽 위 기준 테두리)
//   orb_mouse orb                Dropfit 오브 창 테두리 "x y w h" (정사각형 창 중 가장 작은 것). 없으면 "none"
//   orb_mouse drag X Y DX DY     (X,Y)에서 누르고 DX,DY만큼 끌고 놓기
//   orb_mouse click X Y          (X,Y) 클릭
//   orb_mouse key return|escape  키 하나
import CoreGraphics
import Foundation

func windows() -> [[String: Any]] {
    (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
}

func bounds(_ w: [String: Any]) -> CGRect {
    guard let b = w[kCGWindowBounds as String] as? NSDictionary,
          let r = CGRect(dictionaryRepresentation: b) else { return .zero }
    return r
}

func orbFrame() -> CGRect? {
    windows().filter { ($0[kCGWindowOwnerName as String] as? String) == "Dropfit" }
        .map(bounds)
        .filter { $0.width == $0.height && $0.width > 40 && $0.width < 600 }
        .min { $0.width < $1.width }
}

func post(_ type: CGEventType, _ p: CGPoint) {
    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
    e?.setIntegerValueField(.mouseEventClickState, value: 1)
    e?.post(tap: .cghidEventTap)
    usleep(16_000)
}

let a = CommandLine.arguments
switch a.count > 1 ? a[1] : "" {
case "preflight":
    print("입력 보내기 \(CGPreflightPostEventAccess() ? "허용" : "막힘") · 화면 찍기 \(CGPreflightScreenCaptureAccess() ? "허용" : "막힘")")
case "wins":
    for w in windows() {
        let r = bounds(w)
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        let layer = w[kCGWindowLayer as String] as? Int ?? 0
        print("\(owner) · 층 \(layer) · \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))")
    }
case "orb":
    if let r = orbFrame() { print("\(Int(r.minX)) \(Int(r.minY)) \(Int(r.width)) \(Int(r.height))") } else { print("none") }
case "drag":
    let x = Double(a[2])!, y = Double(a[3])!, dx = Double(a[4])!, dy = Double(a[5])!
    let start = CGPoint(x: x, y: y)
    post(.mouseMoved, start); usleep(150_000)
    post(.leftMouseDown, start); usleep(120_000)
    for i in 1...30 {
        let t = Double(i) / 30
        post(.leftMouseDragged, CGPoint(x: x + dx * t, y: y + dy * t))
    }
    usleep(120_000)
    post(.leftMouseUp, CGPoint(x: x + dx, y: y + dy))
case "click":
    let p = CGPoint(x: Double(a[2])!, y: Double(a[3])!)
    post(.mouseMoved, p); usleep(150_000)
    post(.leftMouseDown, p); usleep(80_000)
    post(.leftMouseUp, p)
case "key":
    let code: CGKeyCode = a[2] == "escape" ? 53 : 36
    for down in [true, false] {
        CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap)
        usleep(30_000)
    }
default:
    print("사용법: orb_mouse preflight|wins|orb|drag X Y DX DY|click X Y|key return|escape")
    exit(2)
}
