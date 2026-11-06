import SwiftUI
import AppKit
#if !NO_SM
import ServiceManagement
#endif

struct SettingsView: View {
    @State var tab = 0
    var selectIndex = 0
    var body: some View {
        TabView(selection: $tab) {
            NodesSettings(selectIndex: selectIndex).tabItem { Label(L("장비", "Machines"), systemImage: "server.rack") }.tag(0)
            GeneralSettings().tabItem { Label(L("일반", "General"), systemImage: "gearshape") }.tag(1)
            SetupGuide().tabItem { Label(L("연결 방법", "Setup guide"), systemImage: "questionmark.circle") }.tag(2)
        }
        .frame(width: 760, height: 560)
    }
}

// MARK: - 장비 목록·편집

struct NodesSettings: View {
    @EnvironmentObject var store: Store
    @State private var selection: String?
    @State private var draft = NodeConfig()
    @State private var testResult: String?
    @State private var testing = false
    @State private var confirmDelete = false
    var selectIndex = 0

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.config.nodes) { n in
                        HStack {
                            Image(systemName: n.kind.icon).frame(width: 16).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(n.name.isEmpty ? L("(이름 없음)", "(unnamed)") : n.name)
                                Text(n.local ? L("이 컴퓨터", "localhost") : n.address).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(n.id)
                    }
                    .onMove { store.move(from: $0, to: $1) }
                }
                HStack(spacing: 4) {
                    Button { addNew() } label: { Image(systemName: "plus") }.help(L("장비 추가", "Add machine"))
                    Button { confirmDelete = true } label: { Image(systemName: "minus") }.disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless).padding(8)
            }
            .frame(width: 220)
            Divider()
            editor
        }
        .onAppear { if selection == nil { let ns = store.config.nodes; selection = ns.indices.contains(selectIndex) ? ns[selectIndex].id : ns.first?.id }; loadDraft() }
        .onChange(of: selection) { loadDraft() }
        .alert(L("이 장비를 목록에서 뺄까요?", "Remove this machine?"), isPresented: $confirmDelete) {
            Button(L("빼기", "Remove"), role: .destructive) {
                if let s = selection { store.remove(s); selection = store.config.nodes.first?.id }
            }
            Button(L("취소", "Cancel"), role: .cancel) {}
        } message: { Text(L("장비 자체에는 아무 변화가 없어요.", "Nothing changes on the machine itself.")) }
    }

    func addNew() {
        var n = NodeConfig(); n.name = L("새 장비", "New machine"); n.user = NSUserName()
        draft = n; selection = nil; testResult = nil
    }
    func loadDraft() {
        testResult = nil
        if let s = selection, let n = store.config.nodes.first(where: { $0.id == s }) { draft = n }
    }
    var isNew: Bool { !store.config.nodes.contains { $0.id == draft.id } }
    var valid: Bool { !draft.name.isEmpty && (draft.local || (!draft.host.isEmpty && !draft.user.isEmpty)) }

    var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField(L("이름", "Name"), text: $draft.name)
                    TextField(L("메모 (역할, 사양 등)", "Note (role, specs…)"), text: $draft.role)
                    if !draft.local {
                        Picker("OS", selection: $draft.kind) { ForEach(NodeKind.allCases) { Text($0.label).tag($0) } }
                    }
                }
                if !draft.local {
                    Section(L("SSH 접속", "SSH connection")) {
                        TextField(L("주소 (IP 또는 호스트 이름)", "Host (IP or hostname)"), text: $draft.host)
                        TextField(L("사용자", "User"), text: $draft.user)
                        TextField(L("포트", "Port"), value: $draft.port, format: .number.grouping(.never))
                        Toggle(L("화면 공유(VNC) 버튼 표시", "Show Screen Sharing (VNC) button"), isOn: $draft.vnc)
                        Toggle(L("항상 켜져 있어야 함 (꺼지면 알림)", "Should always be on (alert when unreachable)"), isOn: $draft.alwaysOn)
                    }
                }
                Section(L("선택 사항", "Optional")) {
                    TextField(L("작업 표시용 잠금 경로", "Busy lock path"), text: $draft.lockPath,
                              prompt: Text(draft.kind == .windows ? "C:\\jobs\\.lock" : "/tmp/render.lock"))
                    if draft.kind != .mac {
                        HStack {
                            TextField(L("대기 전력 (W)", "Idle power (W)"), value: $draft.idleWatts, format: .number)
                            TextField(L("CPU 최대 추가 (W)", "Extra at 100% CPU (W)"), value: $draft.cpuWatts, format: .number)
                        }
                        Text(L("Windows·Linux는 전력 센서를 읽을 수 없어 이 값으로 추정해요. NVIDIA GPU 전력은 실측으로 더해요.",
                               "Windows/Linux power is estimated from these values. NVIDIA GPU power is measured and added."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if !draft.local {
                    Button(testing ? L("확인 중…", "Testing…") : L("연결 테스트", "Test connection")) { test() }.disabled(testing || !valid)
                }
                if let t = testResult { Text(t).font(.caption).foregroundStyle(t.hasPrefix("✓") ? .green : .red).lineLimit(2) }
                Spacer()
                Button(isNew ? L("추가", "Add") : L("저장", "Save")) {
                    store.upsert(draft); selection = draft.id
                }
                .keyboardShortcut(.defaultAction).disabled(!valid)
            }
            .padding(14)
        }
    }

    func test() {
        testing = true; testResult = nil
        let n = draft
        Task {
            let st = await Runner.probe(n)
            testing = false
            if st.state == .online {
                testResult = "✓ " + L("연결됨 · 디스크 여유 \(st.s("disk_free_gb") ?? "?")GB · \(String(format: "%.1f", st.seconds ?? 0))초",
                                      "Connected · \(st.s("disk_free_gb") ?? "?") GB free · \(String(format: "%.1f", st.seconds ?? 0))s")
            } else {
                testResult = "✗ " + (st.error ?? "") + L(" (연결 방법 탭 참고)", " (see Setup guide)")
            }
        }
    }
}

// MARK: - 일반

struct GeneralSettings: View {
    @EnvironmentObject var store: Store
    @State private var c = AppConfig()

    var body: some View {
        Form {
            Section(L("갱신", "Refresh")) {
                Picker(L("확인 주기", "Interval"), selection: $c.pollSeconds) {
                    ForEach([30.0, 60, 120, 300], id: \.self) { Text(L("\(Int($0))초", "\(Int($0)) s")).tag($0) }
                }
                TextField(L("디스크 여유 경고 (GB)", "Low disk warning (GB)"), value: $c.diskWarnGB, format: .number)
            }
            Section(L("전기 요금", "Electricity")) {
                Picker(L("통화", "Currency"), selection: $c.currency) { ForEach(["₩", "$", "€", "£", "¥"], id: \.self) { Text($0).tag($0) } }
                TextField(L("kWh당 요금", "Price per kWh"), value: $c.pricePerKWh, format: .number)
                Text(L("한국 주택용 2단계(201~400kWh) 기준 약 258원. 누진 구간에 맞게 바꿔 쓰세요.",
                       "Use your marginal rate per kWh from your electricity bill."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("앱", "App")) {
                LoginToggle()
                HStack {
                    Text(L("버전 \(AppInfo.version)", "Version \(AppInfo.version)"))
                    Spacer()
                    if let m = store.updateMessage { Text(m).font(.caption).foregroundStyle(.secondary) }
                    Button(L("업데이트 확인", "Check for updates")) { store.checkForUpdates() }
                }
                HStack {
                    Button(L("GitHub 열기", "Open on GitHub")) { NSWorkspace.shared.open(AppInfo.repoURL) }
                    Button(L("설정 폴더 열기", "Open config folder")) { NSWorkspace.shared.open(store.dir) }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { c = store.config }
        .onChange(of: c.pollSeconds) { store.updateGeneral(c) }
        .onChange(of: c.diskWarnGB) { store.updateGeneral(c) }
        .onChange(of: c.currency) { store.updateGeneral(c) }
        .onChange(of: c.pricePerKWh) { store.updateGeneral(c) }
    }
}

struct LoginToggle: View {
#if NO_SM
    var body: some View { Text(L("로그인 시 자동 실행 (테스트 빌드에서는 꺼짐)", "Launch at login (disabled in test build)")) }
#else
    @State private var on = SMAppService.mainApp.status == .enabled
    var body: some View {
        Toggle(L("로그인 시 자동 실행", "Launch at login"), isOn: Binding(get: { on }, set: { v in
            do { if v { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {}
            on = SMAppService.mainApp.status == .enabled
        }))
    }
#endif
}

// MARK: - 연결 방법

struct SetupGuide: View {
    @State private var keyMessage: String?

    var pubKeyURL: URL? {
        let ssh = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        return ["id_ed25519.pub", "id_ecdsa.pub", "id_rsa.pub"].map { ssh.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("Popcorn Nodes는 서버 없이, 이 Mac의 SSH 키로 각 장비에 직접 접속해요. 장비마다 아래를 한 번만 해 두면 됩니다.",
                       "Popcorn Nodes has no server. It connects to each machine directly with this Mac's SSH key. Do this once per machine."))
                    .foregroundStyle(.secondary)

                Step(n: 1, title: L("이 Mac의 SSH 키", "This Mac's SSH key")) {
                    HStack {
                        if pubKeyURL != nil {
                            Button(L("공개 키 복사", "Copy public key")) { copyKey() }
                        } else {
                            Button(L("SSH 키 만들기", "Create SSH key")) { makeKey() }
                        }
                        if let m = keyMessage { Text(m).font(.caption).foregroundStyle(.secondary) }
                    }
                    Text(L("비밀번호(passphrase)가 걸린 키는 macOS 키체인에 등록돼 있어야 해요: ssh-add --apple-use-keychain",
                           "Keys with a passphrase must be in the macOS keychain: ssh-add --apple-use-keychain"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Step(n: 2, title: "macOS") {
                    Text(L("시스템 설정 → 일반 → 공유 → 원격 로그인 켜기. 그다음 이 Mac 터미널에서:",
                           "System Settings → General → Sharing → turn on Remote Login. Then on this Mac:"))
                    Code("ssh-copy-id user@host")
                }
                Step(n: 3, title: "Windows 10/11") {
                    Text(L("관리자 PowerShell에서 OpenSSH 서버를 켜요:", "In an admin PowerShell, enable the OpenSSH server:"))
                    Code("Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0\nStart-Service sshd\nSet-Service sshd -StartupType Automatic")
                    Text(L("공개 키를 관리자 계정이면 C:\\ProgramData\\ssh\\administrators_authorized_keys에, 일반 계정이면 %USERPROFILE%\\.ssh\\authorized_keys에 붙여 넣어요.",
                           "Paste the public key into C:\\ProgramData\\ssh\\administrators_authorized_keys (admin users) or %USERPROFILE%\\.ssh\\authorized_keys (standard users)."))
                        .font(.callout)
                }
                Step(n: 4, title: "Linux") {
                    Code("sudo apt install openssh-server   # Debian/Ubuntu\nssh-copy-id user@host              # " + L("이 Mac에서", "from this Mac"))
                }
                Step(n: 5, title: L("밖에서도 보려면", "Away from home")) {
                    Text(L("Tailscale 같은 VPN을 쓰면 집 밖에서도 같은 주소로 접속돼요. 포트를 인터넷에 직접 열지 마세요.",
                           "Use a VPN such as Tailscale to reach machines from anywhere. Don't expose SSH directly to the internet."))
                }
            }
            .padding(20)
        }
    }

    func copyKey() {
        guard let u = pubKeyURL, let k = try? String(contentsOf: u) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(k.trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)
        keyMessage = L("복사했어요 (\(u.lastPathComponent))", "Copied (\(u.lastPathComponent))")
    }
    func makeKey() {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/id_ed25519").path
        Task {
            let r = await Runner.run("/usr/bin/ssh-keygen", ["-t", "ed25519", "-N", "", "-f", path, "-C", "popcorn-nodes"], timeout: 20)
            keyMessage = r.code == 0 ? L("키를 만들었어요. 이제 복사할 수 있어요.", "Key created. You can copy it now.") : r.err
        }
    }
}

struct Step<Content: View>: View {
    let n: Int, title: String
    @ViewBuilder let content: Content
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.headline).frame(width: 26, height: 26).background(Circle().fill(Color.orange.opacity(0.2)))
            VStack(alignment: .leading, spacing: 6) { Text(title).font(.headline); content }
            Spacer(minLength: 0)
        }
    }
}

struct Code: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        HStack(alignment: .top) {
            Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) } label: {
                Image(systemName: "doc.on.doc")
            }.buttonStyle(.borderless)
        }
        .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
    }
}
