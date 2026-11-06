import Foundation

enum Scripts {
    static func shQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func psQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }

    static func probe(for n: NodeConfig) -> String {
        switch n.kind {
        case .mac: return "LOCK=\(shQuote(n.lockPath))\n" + mac
        case .linux: return "LOCK=\(shQuote(n.lockPath))\n" + linux
        case .windows: return "$lock=\(psQuote(n.lockPath))\n" + windows
        }
    }

    static let mac = #"""
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin
bt=$(sysctl -n kern.boottime 2>/dev/null | sed -E 's/^\{ sec = ([0-9]+),.*/\1/'); [ -n "$bt" ] && echo "uptime_s=$(( $(date +%s) - bt ))"
echo "load1=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')"
echo "ncpu=$(sysctl -n hw.ncpu 2>/dev/null)"
echo "mem_free_pct=$(memory_pressure 2>/dev/null | awk -F': ' '/free percentage/{gsub("%","",$2);print $2}')"
echo "disk_free_gb=$(df -g /System/Volumes/Data 2>/dev/null | awk 'NR==2{print $4}')"
b=$(pmset -g batt); echo "$b" | grep -q "AC Power" && echo "ac=1" || echo "ac=0"
echo "batt_pct=$(echo "$b" | grep -oE '[0-9]+%' | head -1 | tr -d %)"
echo "batt_left=$(echo "$b" | grep -oE '[0-9]+:[0-9]+ remaining' | cut -d' ' -f1)"
io=$(ioreg -rw0 -c AppleSmartBattery)
echo "power_in_mw=$(echo "$io" | grep -oE '"SystemPowerIn"=[0-9]+' | cut -d= -f2)"
echo "load_mw=$(echo "$io" | grep -oE '"SystemLoad"=[0-9]+' | cut -d= -f2)"
[ -n "$LOCK" ] && [ -e "$LOCK" ] && echo "lock=1" || echo "lock=0"
echo "top=$(ps -Ao pcpu=,comm= -r 2>/dev/null | head -1 | awk '{p=$1; $1=""; n=$0; sub(".*/","",n); print p"% "n}')"
"""#

    static let linux = #"""
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin
echo "uptime_s=$(cut -d. -f1 /proc/uptime)"
echo "load1=$(cut -d' ' -f1 /proc/loadavg)"
echo "ncpu=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)"
echo "mem_free_pct=$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{if(t>0)printf "%d", a*100/t}' /proc/meminfo)"
echo "disk_free_gb=$(df -Pk / | awk 'NR==2{printf "%d", $4/1048576}')"
for b in /sys/class/power_supply/BAT*; do [ -e "$b/capacity" ] || continue
  echo "batt_pct=$(cat $b/capacity)"; [ -e "$b/power_now" ] && echo "batt_power_uw=$(cat $b/power_now)"; break; done
ac=1; for a in /sys/class/power_supply/A*/online /sys/class/power_supply/*AC*/online; do [ -e "$a" ] && ac=$(cat "$a") && break; done; echo "ac=$ac"
if command -v nvidia-smi >/dev/null; then IFS=, read -r w u t mu mt < <(nvidia-smi --query-gpu=power.draw,utilization.gpu,temperature.gpu,memory.used,memory.total --format=csv,noheader,nounits | head -1)
  echo "gpu_w=${w// /}"; echo "gpu_util=${u// /}"; echo "gpu_temp=${t// /}"; echo "gpu_mem=${mu// /}/${mt// /}"; fi
[ -n "$LOCK" ] && [ -e "$LOCK" ] && echo "lock=1" || echo "lock=0"
echo "top=$(ps -eo pcpu=,comm= --sort=-pcpu 2>/dev/null | head -1 | awk '{print $1"% "$2}')"
"""#

    static let windows = #"""
$ErrorActionPreference='SilentlyContinue'; $ProgressPreference='SilentlyContinue'
$o=Get-CimInstance Win32_OperatingSystem
"uptime_s="+[int]((Get-Date)-$o.LastBootUpTime).TotalSeconds
"cpu_pct="+[int]((Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average)
"ncpu="+[Environment]::ProcessorCount
"mem_free_pct="+[int](100*$o.FreePhysicalMemory/$o.TotalVisibleMemorySize)
"disk_free_gb="+[math]::Floor((Get-PSDrive C).Free/1GB)
$b=Get-CimInstance -Namespace root\wmi BatteryStatus | Select-Object -First 1
if($b){ "ac="+[int]$b.PowerOnline; "batt_pct="+(Get-CimInstance Win32_Battery | Select-Object -First 1).EstimatedChargeRemaining } else { "ac=1" }
if(Get-Command nvidia-smi){ $g=(& nvidia-smi --query-gpu=power.draw,utilization.gpu,temperature.gpu,memory.used,memory.total --format=csv,noheader,nounits | Select-Object -First 1) -split ',\s*'; "gpu_w="+$g[0]; "gpu_util="+$g[1]; "gpu_temp="+$g[2]; "gpu_mem="+$g[3]+"/"+$g[4] }
"lock="+[int]($lock -ne '' -and (Test-Path $lock))
$p=Get-CimInstance Win32_PerfFormattedData_PerfProc_Process | Where-Object { $_.Name -notin '_Total','Idle' } | Sort-Object PercentProcessorTime -Descending | Select-Object -First 1
"top="+[int]($p.PercentProcessorTime/[Environment]::ProcessorCount)+"% "+($p.Name -replace '#\d+$','')
"""#
}

struct RunResult { var code: Int32; var out: String; var err: String; var timedOut: Bool }

enum Runner {
    static let sshOpts = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6", "-o", "ServerAliveInterval=10", "-o", "StrictHostKeyChecking=accept-new"]

    static func run(_ exe: String, _ args: [String], stdin: String? = nil, timeout: Double) async -> RunResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                var env = ProcessInfo.processInfo.environment
                env["LANG"] = "en_US.UTF-8"
                p.environment = env
                let o = Pipe(), e = Pipe(), i = Pipe()
                p.standardOutput = o; p.standardError = e; p.standardInput = i
                do { try p.run() } catch {
                    cont.resume(returning: RunResult(code: -1, out: "", err: error.localizedDescription, timedOut: false)); return
                }
                if let stdin { i.fileHandleForWriting.write(stdin.data(using: .utf8)!) }
                try? i.fileHandleForWriting.close()
                var timedOut = false
                let killer = DispatchWorkItem { if p.isRunning { timedOut = true; p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let g = DispatchGroup(); var od = Data(), ed = Data()
                g.enter(); DispatchQueue.global().async { od = o.fileHandleForReading.readDataToEndOfFile(); g.leave() }
                g.enter(); DispatchQueue.global().async { ed = e.fileHandleForReading.readDataToEndOfFile(); g.leave() }
                g.wait(); p.waitUntilExit(); killer.cancel()
                cont.resume(returning: RunResult(code: p.terminationStatus,
                                                 out: String(decoding: od, as: UTF8.self).replacingOccurrences(of: "\r", with: ""),
                                                 err: String(decoding: ed, as: UTF8.self), timedOut: timedOut))
            }
        }
    }

    static func psEncoded(_ script: String) -> String {
        "powershell -NoProfile -NonInteractive -EncodedCommand " + script.data(using: .utf16LittleEndian)!.base64EncodedString()
    }

    /// 장비에서 스크립트 실행 (macOS·Linux: bash/sh, Windows: PowerShell)
    static func exec(_ n: NodeConfig, _ script: String, timeout: Double) async -> RunResult {
        if n.local { return await run("/bin/bash", ["-c", script], timeout: timeout) }
        let base = sshOpts + n.sshPortArgs + [n.sshTarget]
        switch n.kind {
        case .mac, .linux:
            return await run("/usr/bin/ssh", base + ["bash -s"], stdin: script, timeout: timeout)
        case .windows:
            let wrapped = "$ProgressPreference='SilentlyContinue'; [Console]::OutputEncoding=[Text.Encoding]::UTF8\n" + script
            return await run("/usr/bin/ssh", base + [psEncoded(wrapped)], timeout: timeout)
        }
    }

    static func probe(_ n: NodeConfig) async -> NodeStatus {
        let t0 = Date()
        let r = await exec(n, Scripts.probe(for: n), timeout: 40)
        var st = NodeStatus(updated: Date(), seconds: Date().timeIntervalSince(t0))
        for line in r.out.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            st.m[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        if st.m["disk_free_gb"] != nil || st.m["uptime_s"] != nil {
            st.state = .online
        } else {
            st.state = .offline
            let msg = r.err.split(separator: "\n").last.map(String.init) ?? ""
            st.error = r.timedOut ? L("응답 시간 초과", "Timed out") : (msg.isEmpty ? L("응답 없음 (코드 \(r.code))", "No response (code \(r.code))") : msg)
        }
        return st
    }
}
