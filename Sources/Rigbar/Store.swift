import Foundation
import AppKit
import UserNotifications

struct EnergyLog: Codable {
    var month: String
    var wh: [String: Double] = [:]
    var lastSample: [String: Date] = [:]
}

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var config: AppConfig
    @Published var status: [String: NodeStatus] = [:]
    @Published var energy: EnergyLog
    @Published var busy = Set<String>()
    @Published var updateMessage: String?
    @Published var newVersion: String?
    var snapshotMode = false
    private var timer: Timer?
    private var activeAlerts: [String: Set<String>] = [:]
    private var seen = Set<String>()

    let dir: URL
    var configURL: URL { dir.appendingPathComponent("nodes.json") }
    var energyURL: URL { dir.appendingPathComponent("energy.json") }

    static func monthKey(_ d: Date = Date()) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"; return f.string(from: d)
    }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = support.appendingPathComponent("Rigbar")
        // 예전 이름(Popcorn Nodes) 설정이 있으면 그대로 옮겨 온다
        let legacy = support.appendingPathComponent("PopcornNodes")
        if !FileManager.default.fileExists(atPath: dir.path), FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.copyItem(at: legacy, to: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cfgURL = dir.appendingPathComponent("nodes.json")
        if let d = try? Data(contentsOf: cfgURL), let c = try? JSONDecoder().decode(AppConfig.self, from: d) {
            config = c
        } else {
            config = AppConfig()
        }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: dir.appendingPathComponent("energy.json")), let e = try? dec.decode(EnergyLog.self, from: d),
           e.month == Store.monthKey() {
            energy = e
        } else {
            energy = EnergyLog(month: Store.monthKey())
        }
        if !FileManager.default.fileExists(atPath: cfgURL.path) { saveConfig() }
    }

    // MARK: 주기 갱신

    func start() {
        requestNotifications()
        refreshAll()
        restartTimer()
    }

    private func restartTimer() {
        guard !snapshotMode else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: config.pollSeconds, repeats: true) { _ in
            Task { @MainActor in Store.shared.refreshAll() }
        }
    }

    func refreshAll() { for n in config.nodes { refresh(n) } }

    func refreshAllAndWait() async {
        await withTaskGroup(of: (String, NodeStatus).self) { g in
            for n in config.nodes { g.addTask { (n.id, await Runner.probe(n)) } }
            for await (id, st) in g { if let n = config.nodes.first(where: { $0.id == id }) { apply(n, st) } }
        }
    }

    func refresh(_ n: NodeConfig) {
        guard !busy.contains(n.id) else { return }
        busy.insert(n.id)
        Task {
            let st = await Runner.probe(n)
            self.busy.remove(n.id)
            if let cur = self.config.nodes.first(where: { $0.id == n.id }) { self.apply(cur, st) }
        }
    }

    private func apply(_ n: NodeConfig, _ st: NodeStatus) {
        status[n.id] = st
        guard !snapshotMode else { return }
        accumulate(n, st)
        let list = st.alerts(n, diskWarn: config.diskWarnGB)
        let now = Set(list.map(\.key))
        let texts = Dictionary(list.map { ($0.key, $0.text) }, uniquingKeysWith: { a, _ in a })
        let before = activeAlerts[n.id] ?? []
        if seen.contains(n.id) {
            for k in now.subtracting(before) { notify("\(n.name): \(texts[k] ?? k)", body: n.role) }
            if before.contains("offline") && st.state == .online && n.alwaysOn { notify(L("\(n.name) 다시 연결됨", "\(n.name) is back online"), body: n.role) }
        } else {
            for k in now { notify("\(n.name): \(texts[k] ?? k)", body: n.role) }
        }
        seen.insert(n.id)
        activeAlerts[n.id] = now
        updateDockBadge()
    }

    private func accumulate(_ n: NodeConfig, _ st: NodeStatus) {
        let key = Store.monthKey()
        if energy.month != key { energy = EnergyLog(month: key) }
        let now = Date()
        defer { energy.lastSample[n.id] = now }
        guard let (w, _) = st.watts(n) else { return }
        let dt = energy.lastSample[n.id].map { now.timeIntervalSince($0) } ?? config.pollSeconds
        energy.wh[n.id, default: 0] += w * min(dt, max(300, config.pollSeconds * 3)) / 3600
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(energy).write(to: energyURL)
    }

    // MARK: 설정 편집

    func saveConfig() {
        guard !snapshotMode else { return }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(config).write(to: configURL)
    }

    func upsert(_ n: NodeConfig) {
        if let i = config.nodes.firstIndex(where: { $0.id == n.id }) { config.nodes[i] = n } else { config.nodes.append(n) }
        saveConfig(); status[n.id] = nil; refresh(n)
    }

    func remove(_ id: String) {
        config.nodes.removeAll { $0.id == id }
        status[id] = nil; activeAlerts[id] = nil; seen.remove(id)
        saveConfig(); updateDockBadge()
    }

    func move(from: IndexSet, to: Int) { config.nodes.move(fromOffsets: from, toOffset: to); saveConfig() }

    func updateGeneral(_ c: AppConfig) {
        let pollChanged = c.pollSeconds != config.pollSeconds
        config.pollSeconds = c.pollSeconds; config.pricePerKWh = c.pricePerKWh
        config.currency = c.currency; config.diskWarnGB = c.diskWarnGB
        saveConfig(); if pollChanged { restartTimer() }
    }

    func reloadConfig() {
        if let d = try? Data(contentsOf: configURL), let c = try? JSONDecoder().decode(AppConfig.self, from: d) {
            config = c; status = status.filter { k, _ in c.nodes.contains { $0.id == k } }; refreshAll(); restartTimer()
        }
    }

    // MARK: 요약

    var onlineCount: Int { config.nodes.filter { status[$0.id]?.state == .online }.count }
    var totalWatts: Double { config.nodes.compactMap { status[$0.id]?.watts($0)?.0 }.reduce(0, +) }
    var monthKWh: Double { energy.wh.values.reduce(0, +) / 1000 }
    var allAlerts: [(NodeConfig, NodeStatus.Alert)] {
        config.nodes.flatMap { n in (status[n.id]?.alerts(n, diskWarn: config.diskWarnGB) ?? []).map { (n, $0) } }
    }

    func updateDockBadge() {
        let c = allAlerts.count
        NSApp?.dockTile.badgeLabel = c > 0 ? "\(c)" : nil
    }

    // MARK: 알림

    private func requestNotifications() {
        guard Bundle.main.bundleIdentifier != nil, !snapshotMode else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    func notify(_ title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil, !snapshotMode else { return }
        let c = UNMutableNotificationContent(); c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: 동작

    func openTerminal(_ n: NodeConfig) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rigbar-\(n.id.prefix(8)).command")
        let port = n.port == 22 ? "" : "-p \(n.port) "
        let cmd = n.local ? "#!/bin/zsh\ncd ~\nexec zsh -l\n" : "#!/bin/zsh\nexec ssh \(port)\(n.sshTarget)\n"
        try? cmd.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }
    func openScreen(_ n: NodeConfig) {
        if let u = URL(string: "vnc://\(n.host)") { NSWorkspace.shared.open(u) }
    }

    // MARK: 업데이트 확인 (GitHub Releases)

    func checkForUpdates(silent: Bool = false) {
        Task {
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(AppInfo.repoSlug)/releases/latest")!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let tag = j["tag_name"] as? String else {
                if !silent { updateMessage = L("업데이트 정보를 가져오지 못했어요.", "Couldn't check for updates.") }
                return
            }
            let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            if latest.compare(AppInfo.version, options: .numeric) == .orderedDescending {
                newVersion = latest
                updateMessage = L("새 버전 \(latest)이 있어요.", "Version \(latest) is available.")
                if !silent, let u = (j["html_url"] as? String).flatMap(URL.init(string:)) { NSWorkspace.shared.open(u) }
            } else if !silent {
                updateMessage = L("최신 버전이에요 (\(AppInfo.version)).", "You're up to date (\(AppInfo.version)).")
            }
        }
    }

    // MARK: 데모 (README 스크린샷용, 실제 접속 없음)

    func loadDemo() {
        snapshotMode = true
        func node(_ name: String, _ role: String, _ kind: NodeKind, _ host: String, alwaysOn: Bool = true, idle: Double = 10, cpu: Double = 30, lock: String = "") -> NodeConfig {
            var n = NodeConfig(); n.id = name; n.name = name; n.role = role; n.kind = kind; n.user = "me"; n.host = host
            n.alwaysOn = alwaysOn; n.idleWatts = idle; n.cpuWatts = cpu; n.lockPath = lock; return n
        }
        var local = NodeConfig.localMac(); local.role = "MacBook Air M3"
        let nodes = [
            local,
            node(L("렌더 맥", "Render Mac"), "Mac mini M2 Pro", .mac, "100.64.0.11", lock: "/tmp/render.lock"),
            node(L("작업용 노트북", "Office laptop"), "Windows 11", .windows, "100.64.0.12", idle: 8, cpu: 35),
            node(L("게이밍 PC", "Gaming PC"), "RTX 4070", .windows, "100.64.0.13", alwaysOn: false, idle: 55, cpu: 90),
            node(L("홈 서버", "Home server"), "Ubuntu 24.04 · NAS", .linux, "100.64.0.14", idle: 15, cpu: 25),
        ]
        config.nodes = nodes; config.pricePerKWh = isKorean ? 258 : 0.17; config.currency = isKorean ? "₩" : "$"
        let now = Date()
        func st(_ m: [String: String]) -> NodeStatus { NodeStatus(state: .online, m: m, updated: now.addingTimeInterval(-8), seconds: 1) }
        status[nodes[0].id] = st(["uptime_s": "380000", "load1": "2.10", "ncpu": "8", "mem_free_pct": "38", "disk_free_gb": "142",
                                  "ac": "1", "batt_pct": "86", "power_in_mw": "14200", "load_mw": "11800", "top": "6.1% Safari"])
        status[nodes[1].id] = st(["uptime_s": "1290000", "load1": "7.40", "ncpu": "12", "mem_free_pct": "31", "disk_free_gb": "11",
                                  "ac": "1", "load_mw": "38200", "lock": "1", "job_name": L("주간 영상 한글 자막 합성", "Weekly video subtitles"), "job_stage": L("3편 중 2편 · 자막 합성 중", "Video 2 of 3 · Burning captions"), "job_tool": "ffmpeg", "job_elapsed_s": "754", "top": "61.0% ffmpeg"])
        status[nodes[2].id] = st(["uptime_s": "1680000", "cpu_pct": "12", "ncpu": "16", "mem_free_pct": "44", "disk_free_gb": "287",
                                  "ac": "0", "batt_pct": "41", "top": "4% chrome"])
        status[nodes[3].id] = NodeStatus(state: .offline, updated: now, error: "Connection timed out")
        status[nodes[4].id] = st(["uptime_s": "4210000", "load1": "0.42", "ncpu": "8", "mem_free_pct": "63", "disk_free_gb": "1830",
                                  "ac": "1", "gpu_w": "18.4", "gpu_util": "3", "gpu_temp": "36", "gpu_mem": "512/12288", "top": "2.0% jellyfin"])
        energy = EnergyLog(month: Store.monthKey(), wh: [nodes[0].id: 2400, nodes[1].id: 5100, nodes[2].id: 2900, nodes[3].id: 3600, nodes[4].id: 4300])
    }
}
