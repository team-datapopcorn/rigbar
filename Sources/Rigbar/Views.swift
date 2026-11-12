import SwiftUI
import AppKit

struct RigbarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Window(AppInfo.name, id: "dashboard") {
            DashboardView().environmentObject(Store.shared).frame(minWidth: 700, minHeight: 520)
        }
        .defaultSize(width: 1040, height: 860)
        Settings {
            SettingsView().environmentObject(Store.shared)
        }
        MenuBarExtra {
            MenuPanel().environmentObject(Store.shared).frame(width: 360)
        } label: {
            MenuLabel().environmentObject(Store.shared)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        Task { @MainActor in
            if CommandLine.arguments.contains("--demo") { Store.shared.loadDemo(); return }
            Store.shared.start(); Store.shared.checkForUpdates(silent: true)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
}

// MARK: - 대시보드

struct DashboardView: View {
    @EnvironmentObject var store: Store
    @State private var commandNode: NodeConfig?
    var scrolls = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if scrolls { ScrollView { content } } else { content; Spacer(minLength: 0) }
        }
        .sheet(item: $commandNode) { n in CommandSheet(node: n).environmentObject(store) }
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let v = store.newVersion {
                HStack {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                    Text(L("새 버전 \(v)이 나왔어요.", "Version \(v) is available."))
                    Spacer()
                    Button(L("다운로드", "Download")) { NSWorkspace.shared.open(AppInfo.repoURL.appendingPathComponent("releases/latest")) }
                }
                .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.12)))
            }
            if !store.allAlerts.isEmpty { alertStrip }
            if store.config.nodes.filter({ !$0.local }).isEmpty { EmptyHint() }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 460), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                ForEach(store.config.nodes) { n in
                    NodeCard(node: n, status: store.status[n.id], busy: store.busy.contains(n.id),
                             diskWarn: store.config.diskWarnGB, onCommand: { commandNode = n })
                }
            }
            EnergyPanel()
        }
        .padding(18)
    }

    var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "server.rack").font(.system(size: 22, weight: .semibold)).foregroundStyle(Color(red: 0.45, green: 0.40, blue: 0.95))
            VStack(alignment: .leading, spacing: 2) {
                Text(AppInfo.name).font(.title2.bold())
                Text(L("온라인 \(store.onlineCount)/\(store.config.nodes.count) · \(Int(store.config.pollSeconds))초마다 갱신",
                       "\(store.onlineCount)/\(store.config.nodes.count) online · every \(Int(store.config.pollSeconds))s"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Stat(title: L("지금 전력", "Power now"), value: "\(Int(store.totalWatts.rounded()))W")
            let monthKWh = store.totalWatts * 24 * 30 / 1000
            Stat(title: L("이 속도로 한 달", "At this rate / month"),
                 value: "\(Int(monthKWh.rounded()))kWh · \(store.config.money(monthKWh * store.config.pricePerKWh))")
            Button { store.refreshAll() } label: { Label(L("새로고침", "Refresh"), systemImage: "arrow.clockwise") }
                .keyboardShortcut("r")
            SettingsLink { Image(systemName: "gearshape") }.help(L("설정", "Settings"))
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    var alertStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(store.allAlerts.enumerated()), id: \.offset) { _, a in
                HStack(spacing: 8) {
                    Image(systemName: a.1.severe ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(a.1.severe ? .red : .orange)
                    Text(a.0.name).bold()
                    Text(a.1.text)
                    Spacer()
                }
            }
        }
        .font(.callout)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.35)))
    }
}

struct EmptyHint: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "plus.circle.fill").font(.system(size: 28)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("원격 장비를 추가해 보세요", "Add your first remote machine")).font(.headline)
                Text(L("SSH로 접속되는 Mac, Windows, Linux 장비를 한 화면에서 봅니다. 설정 → 장비에서 추가하세요.",
                       "Monitor any Mac, Windows or Linux machine you can reach over SSH. Add one in Settings → Machines."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            SettingsLink { Text(L("장비 추가", "Add machine")) }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.orange.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [5])))
    }
}

struct Stat: View {
    let title: String, value: String
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
        }
        .padding(.horizontal, 10)
    }
}

// MARK: - 장비 카드

struct NodeCard: View {
    @EnvironmentObject var store: Store
    let node: NodeConfig
    let status: NodeStatus?
    let busy: Bool
    let diskWarn: Double
    let onCommand: () -> Void
    @State private var confirm: String?

    var st: NodeStatus { status ?? NodeStatus() }
    var dotColor: Color {
        switch st.state { case .online: return st.alerts(node, diskWarn: diskWarn).isEmpty ? .green : .orange
                          case .offline: return node.alwaysOn ? .red : .gray
                          case .unknown: return .gray }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Circle().fill(dotColor).frame(width: 11, height: 11).padding(.top, 6)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(node.name).font(.headline)
                        Image(systemName: node.kind.icon).font(.caption).foregroundStyle(.secondary)
                        if st.lockBusy { Tag(text: L("작업 중", "Busy"), color: .blue) }
                    }
                    Text(node.local ? node.role : [node.role, node.address].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                else if let u = st.updated { Text(u, style: .relative).font(.caption2).foregroundStyle(.tertiary) }
            }

            if st.state == .offline {
                HStack {
                    Image(systemName: "powersleep")
                    Text(node.alwaysOn ? L("연결 안 됨", "Unreachable") : L("꺼져 있음", "Offline"))
                    if let e = st.error { Text("· \(e)").lineLimit(1).foregroundStyle(.tertiary) }
                }
                .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            } else if st.state == .unknown {
                HStack { ProgressView().controlSize(.small); Text(L("확인 중…", "Checking…")) }
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            } else {
                let alerts = st.alerts(node, diskWarn: diskWarn)
                if !alerts.isEmpty {
                    HStack { ForEach(alerts, id: \.key) { Tag(text: $0.text, color: $0.severe ? .red : .orange) } }
                }
                if st.lockBusy { jobDetails }
                if node.kind == .ping {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                        GridRow {
                            Metric(icon: "dot.radiowaves.left.and.right", label: L("응답 시간", "Latency"), value: st.s("latency_ms").map { "\($0) ms" } ?? "-")
                            Metric(icon: "chart.line.downtrend.xyaxis", label: L("패킷 손실", "Packet loss"), value: st.s("loss") ?? "-")
                        }
                    }
                    Text(L("SSH가 없는 장비라 연결 여부만 확인해요.", "No SSH on this device, so only reachability is checked."))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    metrics
                }
            }

            Divider()
            HStack(spacing: 8) {
                if node.kind != .ping {
                    Button { store.openTerminal(node) } label: { Label(L("터미널", "Terminal"), systemImage: "terminal") }
                    if node.vnc && !node.local { Button { store.openScreen(node) } label: { Label(L("화면 공유", "Screen"), systemImage: "display") } }
                    Button(action: onCommand) { Label(L("명령 실행", "Run"), systemImage: "chevron.left.forwardslash.chevron.right") }
                        .disabled(st.state != .online)
                }
                Spacer()
                Button { store.refresh(node) } label: { Image(systemName: "arrow.clockwise") }.help(L("이 장비만 새로고침", "Refresh this machine"))
                if (node.kind == .windows || node.kind == .linux) && !node.local {
                    Menu {
                        Button(L("재시작…", "Restart…")) { confirm = "restart" }
                        Button(L("종료…", "Shut down…")) { confirm = "shutdown" }
                    } label: { Image(systemName: "power") }
                    .menuStyle(.borderlessButton).frame(width: 30).disabled(st.state != .online)
                }
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08)))
        .alert(confirm == "restart" ? L("\(node.name)을(를) 재시작할까요?", "Restart \(node.name)?") : L("\(node.name)을(를) 끌까요?", "Shut down \(node.name)?"),
               isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button(confirm == "restart" ? L("재시작", "Restart") : L("종료", "Shut down"), role: .destructive) { power(confirm == "restart") }
            Button(L("취소", "Cancel"), role: .cancel) {}
        } message: {
            Text(st.lockBusy ? L("지금 작업이 돌고 있어요. 진행 중인 작업이 끊깁니다.", "A job is running and will be interrupted.") :
                 L("열려 있는 프로그램이 닫힙니다.", "Open programs will be closed.")
                 + (node.kind == .linux ? L(" (sudo 권한이 비밀번호 없이 설정돼 있어야 합니다)", " (requires passwordless sudo)") : ""))
        }
    }

    var jobDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(L("진행 중인 작업", "Current job"), systemImage: "gearshape.2")
                    .font(.caption).foregroundStyle(.blue)
                Spacer()
                if let elapsed = st.jobElapsed { Text(elapsed).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
            Text(st.jobTitle).font(.callout.weight(.semibold)).lineLimit(2).textSelection(.enabled)
            if let stage = st.s("job_stage") {
                Text(stage).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else {
                Text(st.s("job_source") == "detected"
                     ? L("실행 폴더 감지 · 작업명·단계 미제공", "Work folder detected · name/stage not provided")
                     : L("상세 단계 미제공", "No stage reported"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let tool = st.s("job_tool") {
                Text(L("실행 도구: ", "Tool: ") + tool).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.07)))
    }

    @ViewBuilder var metrics: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
            GridRow {
                Metric(icon: "cpu", label: "CPU", value: cpuText, bar: st.cpuPercent(node).map { $0 / 100 })
                Metric(icon: "memorychip", label: L("메모리 여유", "Free memory"), value: st.d("mem_free_pct").map { "\(Int($0))%" } ?? "-",
                       bar: st.d("mem_free_pct").map { 1 - $0 / 100 })
            }
            GridRow {
                Metric(icon: "internaldrive", label: L("디스크 여유", "Free disk"), value: st.diskFree.map { "\(Int($0))GB" } ?? "-",
                       warn: (st.diskFree ?? 1e9) < diskWarn)
                Metric(icon: powerIcon, label: L("전원", "Power"), value: powerText, warn: st.onAC == false && !node.local)
            }
            GridRow {
                Metric(icon: "bolt", label: st.watts(node)?.1 == true ? L("소비 전력 (실측)", "Power draw (measured)") : L("소비 전력 (추정)", "Power draw (estimated)"),
                       value: st.watts(node).map { String(format: "%.1fW", $0.0) } ?? "-")
                Metric(icon: "clock", label: L("켜진 지", "Uptime"), value: fmtUptime(st.d("uptime_s")))
            }
            if st.s("gpu_w") != nil {
                GridRow {
                    Metric(icon: "rectangle.3.group", label: "GPU", value: gpuText, bar: st.d("gpu_util").map { $0 / 100 })
                    Metric(icon: "square.stack.3d.up", label: "VRAM", value: vramText)
                }
            }
            GridRow {
                Metric(icon: "flame", label: L("가장 바쁜 프로세스", "Top process"), value: st.s("top") ?? "-").gridCellColumns(2)
            }
        }
    }

    func power(_ restart: Bool) {
        let c: String
        switch node.kind {
        case .windows: c = restart ? "shutdown /r /t 5 /c \"Rigbar\"" : "shutdown /s /t 5 /c \"Rigbar\""
        default: c = restart ? "sudo -n shutdown -r now" : "sudo -n shutdown -h now"
        }
        Task { _ = await Runner.exec(node, c, timeout: 20); try? await Task.sleep(for: .seconds(8)); store.refresh(node) }
    }

    var cpuText: String {
        if node.kind != .windows, let l = st.s("load1"), let c = st.s("ncpu") { return L("부하 \(l) / \(c)코어", "load \(l) / \(c) cores") }
        return st.d("cpu_pct").map { L("\(Int($0))% (\(st.s("ncpu") ?? "?")스레드)", "\(Int($0))% (\(st.s("ncpu") ?? "?") threads)") } ?? "-"
    }
    var gpuText: String {
        let w = st.d("gpu_w").map { "\(Int($0))W" } ?? "-"
        return "\(st.s("gpu_util") ?? "-")% · \(w) · \(st.s("gpu_temp") ?? "-")°C"
    }
    var powerIcon: String {
        guard st.hasBattery else { return "powerplug" }
        return st.onAC == true ? "battery.100.bolt" : "battery.50"
    }
    var powerText: String {
        guard st.hasBattery else { return L("전원 연결", "AC power") }
        let b = st.battery.map { "\($0)%" } ?? ""
        if st.onAC == true { return L("전원 연결 · \(b)", "AC · \(b)") }
        return L("배터리 \(b)", "Battery \(b)") + (st.s("batt_left").map { L(" · \($0) 남음", " · \($0) left") } ?? "")
    }
    var vramText: String {
        guard let s = st.s("gpu_mem") else { return "-" }
        let p = s.split(separator: "/").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return p.count == 2 ? String(format: "%.1f / %.0fGB", p[0] / 1024, p[1] / 1024) : s
    }
}

struct Metric: View {
    let icon: String, label: String, value: String
    var bar: Double? = nil
    var warn = false
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(warn ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.callout.monospacedDigit()).foregroundStyle(warn ? .orange : .primary).lineLimit(1)
                if let bar {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.1))
                            Capsule().fill(bar > 0.85 ? Color.red : bar > 0.6 ? Color.orange : Color.green)
                                .frame(width: max(2, g.size.width * min(1, max(0, bar))))
                        }
                    }.frame(height: 4)
                }
            }
        }
        .frame(minWidth: 190, alignment: .leading)
    }
}

struct Tag: View {
    let text: String, color: Color
    var body: some View {
        Text(text).font(.caption.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18))).foregroundStyle(color)
    }
}

// MARK: - 전기 사용량

struct EnergyPanel: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L("이번 달 전기 사용량", "Energy this month"), systemImage: "bolt.circle").font(.headline)
                Spacer()
                Text(L("앱이 켜져 있는 동안 기록 · kWh당 \(store.config.money(store.config.pricePerKWh, exact: true))",
                       "Recorded while the app runs · \(store.config.money(store.config.pricePerKWh, exact: true))/kWh"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 22) {
                ForEach(store.config.nodes) { n in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(n.name).font(.caption).foregroundStyle(.secondary)
                        Text(String(format: "%.2f kWh", (store.energy.wh[n.id] ?? 0) / 1000)).font(.callout.monospacedDigit())
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(L("합계", "Total")).font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "%.2f kWh · ", store.monthKWh) + store.config.money(store.monthKWh * store.config.pricePerKWh))
                        .font(.headline.monospacedDigit())
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08)))
    }
}

// MARK: - 명령 실행

struct CommandSheet: View {
    let node: NodeConfig
    @Environment(\.dismiss) var dismiss
    @State private var cmd = ""
    @State private var output = ""
    @State private var running = false

    var presets: [(String, String)] {
        switch node.kind {
        case .mac: return [
            (L("상위 프로세스", "Top processes"), "ps -Ao pid,pcpu,pmem,comm -r | head -12"),
            (L("디스크", "Disk"), "df -h /System/Volumes/Data"),
            (L("전원·잠자기", "Power & sleep"), "pmset -g batt; pmset -g | grep -E 'sleep'"),
            (L("launchd 작업", "launchd jobs"), "launchctl list | grep -v com.apple | head -30"),
        ]
        case .linux: return [
            (L("상위 프로세스", "Top processes"), "ps -eo pid,pcpu,pmem,comm --sort=-pcpu | head -12"),
            (L("디스크", "Disk"), "df -h -x tmpfs -x devtmpfs"),
            (L("서비스 오류", "Failed services"), "systemctl --failed --no-pager"),
            (L("GPU 상태", "GPU"), "nvidia-smi || echo 'no nvidia-smi'"),
            (L("Docker", "Docker"), "docker ps --format 'table {{.Names}}\\t{{.Status}}' 2>&1 | head -20"),
        ]
        case .ping: return []
        case .windows: return [
            (L("상위 프로세스", "Top processes"), "Get-Process | Sort-Object CPU -Descending | Select-Object -First 12 Name,Id,CPU,@{n='MB';e={[int]($_.WS/1MB)}} | Format-Table -AutoSize | Out-String -Width 120"),
            (L("GPU 상태", "GPU"), "nvidia-smi"),
            (L("디스크", "Disk"), "Get-PSDrive -PSProvider FileSystem | Format-Table Name,@{n='FreeGB';e={[int]($_.Free/1GB)}},@{n='UsedGB';e={[int]($_.Used/1GB)}} -AutoSize | Out-String"),
            (L("최근 부팅·종료", "Recent boots"), "Get-WinEvent -FilterHashtable @{LogName='System';Id=6005,6006} -MaxEvents 10 | % { $_.TimeCreated.ToString('MM-dd HH:mm') + ' ' + $(if($_.Id -eq 6005){'on'}else{'off'}) }"),
        ]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("\(node.name)에서 명령 실행", "Run on \(node.name)")).font(.headline)
                Text(node.kind == .windows ? "PowerShell" : "bash").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("닫기", "Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack { ForEach(presets, id: \.0) { p in Button(p.0) { cmd = p.1; run() }.controlSize(.small) } }
            HStack {
                TextField(node.kind == .windows ? "Get-Date" : "uptime", text: $cmd)
                    .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced)).onSubmit(run)
                Button(running ? L("실행 중…", "Running…") : L("실행", "Run"), action: run)
                    .disabled(running || cmd.isEmpty).keyboardShortcut(.defaultAction)
            }
            ScrollView {
                Text(output.isEmpty ? L("결과가 여기 표시됩니다.", "Output appears here.") : output)
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35)))
        }
        .padding(18).frame(width: 760, height: 520)
    }

    func run() {
        guard !cmd.isEmpty, !running else { return }
        running = true; output = "$ \(cmd)\n"
        let c = cmd
        Task {
            let r = await Runner.exec(node, c, timeout: 120)
            output += r.out + (r.err.isEmpty || r.err.contains("CLIXML") ? "" : "\n[stderr]\n" + r.err)
            if r.timedOut { output += L("\n(120초 시간 초과)", "\n(timed out after 120s)") }
            running = false
        }
    }
}

// MARK: - 메뉴 막대

struct MenuLabel: View {
    @EnvironmentObject var store: Store
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: store.allAlerts.isEmpty ? "server.rack" : "exclamationmark.triangle.fill")
            Text("\(store.onlineCount)/\(store.config.nodes.count)")
        }
    }
}

struct MenuPanel: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(AppInfo.name).font(.headline)
                Spacer()
                Text("\(Int(store.totalWatts.rounded()))W").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            ForEach(store.config.nodes) { n in row(n) }
            Divider()
            HStack {
                Button(L("대시보드", "Dashboard")) { openWindow(id: "dashboard"); NSApp.activate(ignoringOtherApps: true) }
                SettingsLink { Text(L("설정", "Settings")) }
                Button(L("새로고침", "Refresh")) { store.refreshAll() }
                Spacer()
                Button(L("종료", "Quit")) { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
    }

    @ViewBuilder func row(_ n: NodeConfig) -> some View {
        let st = store.status[n.id] ?? NodeStatus()
        let alerts = st.alerts(n, diskWarn: store.config.diskWarnGB)
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(st.state == .online ? (alerts.isEmpty ? Color.green : .orange) : (n.alwaysOn && st.state == .offline ? .red : .gray))
                .frame(width: 9, height: 9).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(n.name).font(.callout.weight(.medium))
                if st.state == .online {
                    Text(summary(n, st)).font(.caption).foregroundStyle(.secondary)
                    ForEach(alerts, id: \.key) { Text($0.text).font(.caption).foregroundStyle($0.severe ? .red : .orange) }
                } else {
                    Text(st.state == .offline ? (n.alwaysOn ? L("연결 끊김", "Unreachable") : L("꺼져 있음", "Offline")) : L("확인 중…", "Checking…"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if st.state == .online && n.kind != .ping {
                Button { store.openTerminal(n) } label: { Image(systemName: "terminal") }.buttonStyle(.borderless)
                if n.vnc && !n.local { Button { store.openScreen(n) } label: { Image(systemName: "display") }.buttonStyle(.borderless) }
            }
        }
    }

    func summary(_ n: NodeConfig, _ st: NodeStatus) -> String {
        var p: [String] = []
        if let l = st.s("latency_ms") { p.append(L("응답 \(l)ms", "\(l) ms")) }
        if let c = st.cpuPercent(n) { p.append("CPU \(Int(c))%") }
        if let w = st.watts(n) { p.append("\(Int(w.0.rounded()))W") }
        if let f = st.diskFree { p.append(L("디스크 \(Int(f))GB", "\(Int(f))GB free")) }
        if st.lockBusy { p.append(L("작업 중", "busy")) }
        return p.joined(separator: " · ")
    }
}

// MARK: - 아이콘

struct AppIconView: View {
    // 짙은 남보라 바탕 위에 장비 3대(rig)가 쌓인 모양, 각 장비의 상태 점
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 230, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.13, blue: 0.36), Color(red: 0.05, green: 0.06, blue: 0.14)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 230, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 6))
                .padding(100)
            VStack(spacing: 46) {
                ForEach(0..<3, id: \.self) { i in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 44, style: .continuous)
                            .fill(LinearGradient(colors: [Color.white.opacity(0.95), Color(red: 0.82, green: 0.84, blue: 0.95)],
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(width: 560, height: 150)
                        HStack(spacing: 26) {
                            Circle().fill([Color(red: 0.2, green: 0.85, blue: 0.45), Color(red: 0.2, green: 0.85, blue: 0.45), Color(red: 1, green: 0.62, blue: 0.15)][i])
                                .frame(width: 54, height: 54)
                                .shadow(color: [Color.green, Color.green, Color.orange][i].opacity(0.8), radius: 22)
                            ForEach(0..<3, id: \.self) { _ in Capsule().fill(Color(red: 0.16, green: 0.13, blue: 0.36).opacity(0.25)).frame(width: 64, height: 18) }
                        }
                        .padding(.leading, 54)
                    }
                }
            }
        }
        .frame(width: 1024, height: 1024)
    }
}
