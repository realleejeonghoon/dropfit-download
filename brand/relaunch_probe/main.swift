import AppKit

/// 다시 열기 시험 앱 (Dropfit과 무관). 실행 인자로 방식을 받는다:
///   A: 자식 /bin/sh가 이 앱이 끝나길 기다렸다가 표시 파일을 만든다 (Dropfit AppMover.relaunch와 같은 방식)
///   B: 같은 셸을 새 세션(setsid)으로 띄운다
///   C: macOS(LaunchServices)에 새 인스턴스를 열어 달라고 하고(인자 --after <pid>), 새 인스턴스가 이 앱이 끝나길 기다렸다가 표시 파일을 만든다
/// 표시 파일: <폴더>/<방식>.ok  ← 이것이 생기면 "다시 열기"가 살아남은 것
let args = CommandLine.arguments
let dir = ProcessInfo.processInfo.environment["RT_DIR"] ?? "/tmp"
final class D: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--after"), i + 2 < a.count, let pid = Int32(a[i + 1]) {
            // C의 새 인스턴스: 이전 앱이 끝날 때까지 기다린 뒤 표시
            while kill(pid, 0) == 0 { usleep(100_000) }
            FileManager.default.createFile(atPath: a[i + 2], contents: Data("ok".utf8))
            NSApp.terminate(nil); return
        }
        guard let mi = a.firstIndex(of: "--mode"), mi + 2 < a.count else { NSApp.terminate(nil); return }
        let mode = a[mi + 1], out = a[mi + 2]
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; sleep 0.5; /usr/bin/touch \"$0\""
        switch mode {
        case "A":
            let t = Process(); t.executableURL = URL(fileURLWithPath: "/bin/sh"); t.arguments = ["-c", script, out]; try? t.run()
        case "B":
            var attr: posix_spawnattr_t? = nil; posix_spawnattr_init(&attr)
            posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
            var p: pid_t = 0
            let argv: [UnsafeMutablePointer<CChar>?] = ["/bin/sh", "-c", script, out].map { strdup($0) } + [nil]
            posix_spawn(&p, "/bin/sh", nil, &attr, argv, environ)
        case "C":
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.createsNewApplicationInstance = true; cfg.activates = false
            cfg.arguments = ["--after", String(pid), out]
            let sem = DispatchSemaphore(value: 0)
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in sem.signal() }
            _ = sem.wait(timeout: .now() + 5)
        default: break
        }
        NSApp.terminate(nil)
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let d = D(); app.delegate = d
app.run()
