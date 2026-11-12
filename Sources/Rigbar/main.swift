import AppKit
import SwiftUI

func dbg(_ s: String) { if ProcessInfo.processInfo.environment["PN_DEBUG"] != nil { FileHandle.standardError.write((s+"\n").data(using: .utf8)!) } }
dbg("start")
let args = CommandLine.arguments

func arg(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

@MainActor func renderPNG<V: View>(_ view: V, to path: String, scale: CGFloat = 2) {
    let r = ImageRenderer(content: view); r.scale = scale
    if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path)); print("wrote \(path)")
    } else { print("render failed") }
}

@MainActor func shot<V: View>(_ v: V, _ size: CGSize, _ path: String, _ dark: Bool) async {
    let host = NSHostingView(rootView: v.background(Color(nsColor: .windowBackgroundColor)))
    var size = size
    if size.height == 0 { host.frame = CGRect(x: 0, y: 0, width: size.width, height: 2000); size.height = ceil(host.fittingSize.height) }
    host.frame = CGRect(origin: .zero, size: size)
    let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    win.contentView = host
    win.setFrameOrigin(NSPoint(x: -30000, y: -30000))
    win.orderFrontRegardless()
    try? await Task.sleep(for: .milliseconds(1200))
    host.layoutSubtreeIfNeeded(); host.display()
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    host.cacheDisplay(in: host.bounds, to: rep)
    if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)); print("wrote \(path)") }
    win.orderOut(nil)
}

if args.contains("--probe") {
    // 터미널에서 상태만 출력

    Task { @MainActor in
        dbg("task"); let s = Store.shared; dbg("store"); s.snapshotMode = true
        await s.refreshAllAndWait(); dbg("probed")
        for n in s.config.nodes {
            let st = s.status[n.id]
            print("[\(n.name)] \(st?.state == .online ? "online" : "offline") \(String(format: "%.1fs", st?.seconds ?? 0)) \(st?.error ?? "")")
            for (k, v) in (st?.m ?? [:]).sorted(by: { $0.key < $1.key }) { print("   \(k)=\(v)") }
        }
        exit(0)
    }
    dispatchMain()
} else if let path = arg("--snapshot") {
    DispatchQueue.global().asyncAfter(deadline: .now() + 90) { FileHandle.standardError.write("snapshot timeout\n".data(using: .utf8)!); exit(2) }
    let app = NSApplication.shared; app.setActivationPolicy(.prohibited)

    Task { @MainActor in
        let s = Store.shared; s.snapshotMode = true
        if args.contains("--demo") { s.loadDemo() } else { await s.refreshAllAndWait() }
        dbg("probed")
        renderPNG(DashboardView(scrolls: false).environmentObject(s).frame(width: 1040, height: Double(arg("--height") ?? "1080") ?? 1080)
                    .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, args.contains("--light") ? .light : .dark), to: path)
        if let m = arg("--menu") {
            renderPNG(MenuPanel().environmentObject(s).frame(width: 360).background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.colorScheme, args.contains("--light") ? .light : .dark), to: m)
        }
        exit(0)
    }
    app.run()
} else if let dir = arg("--selfshot") {
    // 실제 AppKit 컨트롤로 창을 그려 PNG 저장 (README·검증용)
    DispatchQueue.global().asyncAfter(deadline: .now() + 120) { exit(2) }
    let app = NSApplication.shared; app.setActivationPolicy(.accessory)
    Task { @MainActor in
        let s = Store.shared; s.snapshotMode = true
        if args.contains("--demo") { s.loadDemo() } else { await s.refreshAllAndWait() }
        let dark = !args.contains("--light")
        let h = Double(arg("--height") ?? "1290") ?? 1290
        await shot(DashboardView(scrolls: false).environmentObject(s), CGSize(width: 1040, height: h), "\(dir)/dashboard.png", dark)
        await shot(MenuPanel().environmentObject(s).frame(width: 360).fixedSize(), CGSize(width: 360, height: 0), "\(dir)/menu.png", dark)
        await shot(NodesSettings(selectIndex: 2).environmentObject(s), CGSize(width: 760, height: 540), "\(dir)/machines.png", dark)
        for t in 0..<3 {
            await shot(SettingsView(tab: t, selectIndex: 2).environmentObject(s), CGSize(width: 760, height: 590), "\(dir)/settings-\(t).png", dark)
        }
        exit(0)
    }
    app.run()
} else if let path = arg("--icon") {

    let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
    Task { @MainActor in renderPNG(AppIconView().frame(width: 1024, height: 1024), to: path, scale: 1); exit(0) }
    app.run()
} else {
    RigbarApp.main()
}
