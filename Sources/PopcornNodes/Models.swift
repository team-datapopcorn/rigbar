import Foundation

// MARK: - 언어

let isKorean: Bool = Locale.preferredLanguages.first?.hasPrefix("ko") ?? false
func L(_ ko: String, _ en: String) -> String { isKorean ? ko : en }

enum AppInfo {
    static let name = "Popcorn Nodes"
    static let repoSlug = "team-datapopcorn/popcorn-nodes"
    static var repoURL: URL { URL(string: "https://github.com/\(repoSlug)")! }
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
}

// MARK: - 설정

enum NodeKind: String, Codable, CaseIterable, Identifiable {
    case mac, windows, linux
    var id: String { rawValue }
    var label: String { switch self { case .mac: return "macOS"; case .windows: return "Windows"; case .linux: return "Linux" } }
    var icon: String { switch self { case .mac: return "apple.logo"; case .windows: return "pc"; case .linux: return "terminal" } }
}

struct NodeConfig: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var name: String = ""
    var role: String = ""
    var kind: NodeKind = .mac
    var local: Bool = false
    var user: String = ""
    var host: String = ""
    var port: Int = 22
    var vnc: Bool = true
    /// 꺼지면 알림 (항상 켜져 있어야 하는 장비만)
    var alwaysOn: Bool = true
    /// 전력 추정 (W): 대기 + CPU 100% 추가분. 맥은 센서 실측, GPU는 nvidia-smi 실측을 더함
    var idleWatts: Double = 10
    var cpuWatts: Double = 30
    /// 이 경로가 있으면 "작업 중" 표시 (선택)
    var lockPath: String = ""

    var sshTarget: String { "\(user)@\(host)" }
    var sshPortArgs: [String] { port == 22 ? [] : ["-p", String(port)] }
    var address: String { port == 22 ? host : "\(host):\(port)" }

    init() {}
    static func localMac() -> NodeConfig {
        var n = NodeConfig(); n.id = "local"; n.name = L("이 Mac", "This Mac"); n.local = true; n.vnc = false; n.alwaysOn = false
        return n
    }

    enum CodingKeys: String, CodingKey { case id, name, role, kind, local, user, host, port, vnc, alwaysOn, idleWatts, cpuWatts, lockPath }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decodeIfPresent(NodeKind.self, forKey: .kind) ?? .mac
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        local = try c.decodeIfPresent(Bool.self, forKey: .local) ?? false
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        vnc = try c.decodeIfPresent(Bool.self, forKey: .vnc) ?? !local
        alwaysOn = try c.decodeIfPresent(Bool.self, forKey: .alwaysOn) ?? true
        idleWatts = try c.decodeIfPresent(Double.self, forKey: .idleWatts) ?? 10
        cpuWatts = try c.decodeIfPresent(Double.self, forKey: .cpuWatts) ?? 30
        lockPath = try c.decodeIfPresent(String.self, forKey: .lockPath) ?? ""
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(role, forKey: .role)
        try c.encode(kind, forKey: .kind); try c.encode(local, forKey: .local); try c.encode(user, forKey: .user)
        try c.encode(host, forKey: .host); try c.encode(port, forKey: .port); try c.encode(vnc, forKey: .vnc)
        try c.encode(alwaysOn, forKey: .alwaysOn); try c.encode(idleWatts, forKey: .idleWatts)
        try c.encode(cpuWatts, forKey: .cpuWatts); try c.encode(lockPath, forKey: .lockPath)
    }
}

struct AppConfig: Codable {
    var pollSeconds: Double = 60
    var pricePerKWh: Double = isKorean ? 258 : 0.17
    var currency: String = isKorean ? "₩" : "$"
    var diskWarnGB: Double = 15
    var nodes: [NodeConfig] = [.localMac()]

    init() {}
    enum CodingKeys: String, CodingKey { case pollSeconds, pricePerKWh, currency, diskWarnGB, nodes }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        nodes = try c.decodeIfPresent([NodeConfig].self, forKey: .nodes) ?? []
        pollSeconds = max(15, try c.decodeIfPresent(Double.self, forKey: .pollSeconds) ?? 60)
        if let p = try c.decodeIfPresent(Double.self, forKey: .pricePerKWh) { pricePerKWh = p }
        if let cur = try c.decodeIfPresent(String.self, forKey: .currency) { currency = cur }
        diskWarnGB = try c.decodeIfPresent(Double.self, forKey: .diskWarnGB) ?? 15
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(pollSeconds, forKey: .pollSeconds); try c.encode(pricePerKWh, forKey: .pricePerKWh)
        try c.encode(currency, forKey: .currency); try c.encode(diskWarnGB, forKey: .diskWarnGB); try c.encode(nodes, forKey: .nodes)
    }

    func money(_ v: Double, exact: Bool = false) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        if currency == "₩" || currency == "¥" {
            f.maximumFractionDigits = exact ? 1 : 0
            let r = (currency == "₩" && !exact) ? (v / 100).rounded() * 100 : (exact ? v : v.rounded())
            return currency + (f.string(from: NSNumber(value: r)) ?? "\(Int(r))")
        }
        f.minimumFractionDigits = 2; f.maximumFractionDigits = 2
        return currency + (f.string(from: NSNumber(value: v)) ?? String(format: "%.2f", v))
    }
}

// MARK: - 상태

enum NodeState { case unknown, online, offline }

struct NodeStatus {
    var state: NodeState = .unknown
    var m: [String: String] = [:]
    var updated: Date?
    var error: String?
    var seconds: Double?

    func s(_ k: String) -> String? { let v = m[k]?.trimmingCharacters(in: .whitespaces); return (v?.isEmpty ?? true) ? nil : v }
    func d(_ k: String) -> Double? { s(k).flatMap { Double($0) } }
    /// ioreg 값은 음수가 부호 없는 64비트로 찍힐 때가 있어 보정
    func mw(_ k: String) -> Double? {
        guard let v = s(k), let u = UInt64(v) else { return nil }
        return Double(abs(Int64(bitPattern: u)))
    }

    var onAC: Bool? { d("ac").map { $0 >= 1 } }
    var battery: Int? { d("batt_pct").map { Int($0) } }
    var diskFree: Double? { d("disk_free_gb") }
    var lockBusy: Bool { d("lock") == 1 }
    var hasBattery: Bool { s("batt_pct") != nil }

    func cpuPercent(_ n: NodeConfig) -> Double? {
        if n.kind == .windows { return d("cpu_pct") }
        guard let l = d("load1"), let c = d("ncpu"), c > 0 else { return nil }
        return min(100, l / c * 100)
    }

    /// (와트, 실측 여부)
    func watts(_ n: NodeConfig) -> (Double, Bool)? {
        guard state == .online else { return nil }
        if n.kind == .mac {
            let pin = mw("power_in_mw") ?? 0, load = mw("load_mw") ?? 0
            let w = (pin > 0 ? pin : load) / 1000
            return w > 0 ? (w, true) : nil
        }
        if n.kind == .linux, onAC == false, let uw = d("batt_power_uw"), uw > 0 { return (uw / 1_000_000, true) }
        let cpu = cpuPercent(n) ?? 0, gpu = d("gpu_w") ?? 0
        return (n.idleWatts + n.cpuWatts * cpu / 100 + gpu, false)
    }

    struct Alert: Hashable { let key: String; let text: String; let severe: Bool }
    func alerts(_ n: NodeConfig, diskWarn: Double) -> [Alert] {
        var a: [Alert] = []
        if state == .offline { if n.alwaysOn { a.append(.init(key: "offline", text: L("연결 끊김", "Unreachable"), severe: true)) }; return a }
        guard state == .online else { return a }
        if hasBattery, onAC == false, !n.local {
            var t = L("배터리로 동작 중", "On battery") + (battery.map { " \($0)%" } ?? "")
            if let l = s("batt_left") { t += L(" · \(l) 남음", " · \(l) left") }
            a.append(.init(key: "battery", text: t, severe: (battery ?? 100) < 30))
        }
        if n.local, onAC == false, let b = battery, b < 20 { a.append(.init(key: "lowbatt", text: L("배터리 \(b)%", "Battery \(b)%"), severe: true)) }
        if let f = diskFree, f < diskWarn {
            a.append(.init(key: "disk", text: L("디스크 여유 \(Int(f))GB", "\(Int(f)) GB free"), severe: f < diskWarn / 2))
        }
        return a
    }
}

func fmtUptime(_ s: Double?) -> String {
    guard let s, s > 0, s < 3e7 else { return "-" }
    let d = Int(s) / 86400, h = Int(s) % 86400 / 3600, m = Int(s) % 3600 / 60
    if d > 0 { return L("\(d)일 \(h)시간", "\(d)d \(h)h") }
    if h > 0 { return L("\(h)시간 \(m)분", "\(h)h \(m)m") }
    return L("\(m)분", "\(m)m")
}
