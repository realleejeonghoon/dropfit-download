// 사용자 상태 점검 도우미 (state_app_mac.sh): Dropfit 창 찾기, 앱을 앞으로 하고 단축키 보내기
//   state_probe wins            Dropfit 창 목록 (이름 · 층 · 폭x높이)
//   state_probe settings        설정 창이 보이면 'yes'
//   state_probe press KEY       Dropfit을 앞으로 하고 ⌘KEY (comma = 설정, w = 창 닫기) 또는 escape
import AppKit

let a = CommandLine.arguments
func windows() -> [(name: String, layer: Int, w: Int, h: Int)] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { d in
        guard d[kCGWindowOwnerName as String] as? String == "Dropfit" else { return nil }
        let b = d[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        return (d[kCGWindowName as String] as? String ?? "", d[kCGWindowLayer as String] as? Int ?? 0, Int(b["Width"] ?? 0), Int(b["Height"] ?? 0))
    }
}
func post(_ code: CGKeyCode, cmd: Bool) {
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        if cmd { e?.flags = .maskCommand }
        e?.post(tap: .cghidEventTap)
        usleep(30_000)
    }
}
switch a.count > 1 ? a[1] : "" {
case "wins":
    for w in windows() { print("\(w.name) · 층 \(w.layer) · \(w.w)x\(w.h)") }
case "settings":
    print(windows().contains { $0.layer == 0 && ($0.name.contains("설정") || $0.name.contains("Settings")) } ? "yes" : "no")
case "press":
    NSRunningApplication.runningApplications(withBundleIdentifier: "app.dropfit.prototype").first?.activate()
    usleep(300_000)
    switch a.count > 2 ? a[2] : "" {
    case "comma": post(43, cmd: true)
    case "w": post(13, cmd: true)
    default: post(53, cmd: false)
    }
default:
    print("사용법: state_probe wins|settings|press comma|w|escape"); exit(2)
}
