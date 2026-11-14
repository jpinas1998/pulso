import Darwin
import Foundation

// Escáner de procesos y sockets con libproc: el equivalente a `lsof -iTCP -sTCP:LISTEN`
// pero sin lanzar ningún proceso (unos pocos milisegundos para todo el sistema).

enum SockProto: String, Codable {
    case tcp = "TCP", udp = "UDP"
}

struct Listener: Hashable {
    var port: Int
    var proto: SockProto
    var exposed: Bool   // escucha en todas las interfaces (accesible desde la red)
}

struct ProcInfo {
    let pid: pid_t
    let ppid: pid_t
    let uid: uid_t
    let start: UInt64
    let name: String
    let path: String
    var cwd: String?
    var footprint: UInt64?
    var cpu: Double?            // fracción de toda la máquina (0...1)
    var power: Double?          // vatios (energía medida por el sistema en Apple Silicon)
    var listeners: [Listener] = []

    var isMine: Bool { uid == getuid() }
}

final class ProcessScanner: @unchecked Sendable {
    private let myUID = getuid()
    private var lastCPU: [pid_t: (start: UInt64, ns: UInt64)] = [:]
    private var lastEnergy: [pid_t: (start: UInt64, nj: UInt64)] = [:]
    private var lastScanNs: UInt64 = 0
    private var argsCache: [pid_t: (start: UInt64, args: [String])] = [:]
    private lazy var argBuffer = [UInt8](repeating: 0, count: Self.argmax)
    private let timebase: (numer: UInt64, denom: UInt64) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return (UInt64(tb.numer), UInt64(max(tb.denom, 1)))
    }()

    func scan(includeUDP: Bool) -> [pid_t: ProcInfo] {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let elapsed = lastScanNs > 0 ? Double(nowNs - lastScanNs) : 0
        let cores = Double(SystemSampler.coreCount)
        var newCPU: [pid_t: (start: UInt64, ns: UInt64)] = [:]
        var newEnergy: [pid_t: (start: UInt64, nj: UInt64)] = [:]
        var out: [pid_t: ProcInfo] = [:]

        for pid in Self.allPids() where pid > 0 {
            guard let bsd = Self.bsdInfo(pid) else { continue }
            let path = Self.path(pid)
            var name = Self.string(fromTuple: bsd.pbi_name)
            if name.isEmpty { name = Self.string(fromTuple: bsd.pbi_comm) }
            if name.isEmpty { name = (path as NSString).lastPathComponent }

            var p = ProcInfo(pid: pid, ppid: pid_t(bsd.pbi_ppid), uid: bsd.pbi_uid,
                             start: bsd.pbi_start_tvsec, name: name, path: path)
            p.listeners = listeners(pid: pid, includeUDP: includeUDP)

            if bsd.pbi_uid == myUID {
                p.cwd = Self.cwd(pid)
                if let (footprint, cpuNs, energy) = rusage(pid) {
                    p.footprint = footprint
                    newCPU[pid] = (bsd.pbi_start_tvsec, cpuNs)
                    newEnergy[pid] = (bsd.pbi_start_tvsec, energy)
                    if elapsed > 0, let prev = lastCPU[pid], prev.start == bsd.pbi_start_tvsec, cpuNs >= prev.ns {
                        p.cpu = min(1, Double(cpuNs - prev.ns) / elapsed / cores)
                    }
                    if elapsed > 0, let prev = lastEnergy[pid], prev.start == bsd.pbi_start_tvsec, energy >= prev.nj {
                        p.power = Double(energy - prev.nj) / elapsed      // nJ / ns = W
                    }
                }
            }
            out[pid] = p
        }

        lastCPU = newCPU
        lastEnergy = newEnergy
        lastScanNs = nowNs
        argsCache = argsCache.filter { out[$0.key]?.start == $0.value.start }
        return out
    }

    /// Argumentos de la línea de comandos (KERN_PROCARGS2), cacheados por proceso.
    func arguments(_ p: ProcInfo) -> [String] {
        if let c = argsCache[p.pid], c.start == p.start { return c.args }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, p.pid]
        var size = argBuffer.count
        var args: [String] = []
        let ok = argBuffer.withUnsafeMutableBytes { buf -> Bool in
            sysctl(&mib, 3, buf.baseAddress, &size, nil, 0) == 0 && size > 4
        }
        if ok {
            let argc = argBuffer.withUnsafeBytes { $0.load(as: Int32.self) }
            var i = 4
            while i < size && argBuffer[i] != 0 { i += 1 }   // ruta del ejecutable
            while i < size && argBuffer[i] == 0 { i += 1 }   // relleno
            while args.count < Int(argc) && i < size {
                let s = i
                while i < size && argBuffer[i] != 0 { i += 1 }
                args.append(String(decoding: argBuffer[s..<i], as: UTF8.self))
                i += 1
            }
        }
        argsCache[p.pid] = (p.start, args)
        return args
    }

    /// Línea de comandos completa de un proceso: ejecutable, argumentos, entorno y carpeta de trabajo.
    /// Se usa para reiniciar un servidor exactamente igual que estaba.
    struct CommandLine {
        var executable: String
        var args: [String]
        var env: [String: String]
        var cwd: String
    }

    /// Proceso que hay que relanzar para reiniciar una fila: el primero (de padre a hijo) que no sea una shell.
    /// Las subshells de `cmd &` conservan los argumentos del script que las creó, así que relanzarlas
    /// repetiría el script entero. Si todos son shells (un lanzador como dev.sh), se usa el primero.
    static func restartRoot(_ pids: [pid_t]) -> pid_t? {
        let shells: Set<String> = ["bash", "zsh", "sh", "dash", "fish", "nohup"]
        return pids.first { pid in
            guard let cl = commandLine(of: pid) else { return false }
            return !shells.contains((cl.executable as NSString).lastPathComponent)
        } ?? pids.first
    }

    static func commandLine(of pid: pid_t) -> CommandLine? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = argmax
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = 4
        let exeStart = i
        while i < size && buf[i] != 0 { i += 1 }
        let exe = String(decoding: buf[exeStart..<i], as: UTF8.self)
        while i < size && buf[i] == 0 { i += 1 }
        var strings: [String] = []
        while i < size {
            let s = i
            while i < size && buf[i] != 0 { i += 1 }
            if s == i { break }                       // fin del entorno
            strings.append(String(decoding: buf[s..<i], as: UTF8.self))
            i += 1
        }
        let args = Array(strings.prefix(Int(argc)))
        var env: [String: String] = [:]
        for kv in strings.dropFirst(Int(argc)) {
            if let eq = kv.firstIndex(of: "=") { env[String(kv[..<eq])] = String(kv[kv.index(after: eq)...]) }
        }
        guard let cwd = cwd(pid), !args.isEmpty else { return nil }
        return CommandLine(executable: exe, args: args, env: env, cwd: cwd)
    }

    // MARK: - libproc

    private static let argmax: Int = {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var v: Int32 = 0
        var s = MemoryLayout<Int32>.size
        sysctl(&mib, 2, &v, &s, nil, 0)
        return Int(max(v, 4096))
    }()

    static func allPids() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return Array(pids.prefix(Int(max(count, 0))))
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private static func path(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let r = proc_pidpath(pid, &buf, UInt32(buf.count))
        return r > 0 ? String(cString: buf) : ""
    }

    static func cwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let s = string(fromTuple: info.pvi_cdir.vip_path)
        return s.isEmpty ? nil : s
    }

    /// (memoria real, tiempo de CPU en ns, energía acumulada en nJ)
    private func rusage(_ pid: pid_t) -> (UInt64, UInt64, UInt64)? {
        var ri = rusage_info_v6()
        let r = withUnsafeMutablePointer(to: &ri) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        guard r == 0 else { return nil }
        // En Apple Silicon los tiempos vienen en unidades de mach_absolute_time.
        let ticks = ri.ri_user_time + ri.ri_system_time
        return (ri.ri_phys_footprint, ticks * timebase.numer / timebase.denom, ri.ri_energy_nj)
    }

    private func listeners(pid: pid_t, includeUDP: Bool) -> [Listener] {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return [] }

        var found: [String: Listener] = [:]
        let siSize = Int32(MemoryLayout<socket_fdinfo>.size)
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var si = socket_fdinfo()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, siSize) == siSize else { continue }
            let psi = si.psi
            guard psi.soi_family == AF_INET || psi.soi_family == AF_INET6 else { continue }

            let ini: in_sockinfo
            let proto: SockProto
            if psi.soi_kind == SOCKINFO_TCP {
                let tcp = psi.soi_proto.pri_tcp
                guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
                ini = tcp.tcpsi_ini
                proto = .tcp
            } else if includeUDP, psi.soi_kind == SOCKINFO_IN, psi.soi_protocol == IPPROTO_UDP {
                ini = psi.soi_proto.pri_in
                guard ini.insi_fport == 0 else { continue }   // UDP "conectado" = cliente, no servidor
                proto = .udp
            } else {
                continue
            }

            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport)))
            guard port > 0 else { continue }
            let exposed = Self.isExposed(ini)
            let key = "\(proto.rawValue)\(port)"
            if let prev = found[key] {
                found[key] = Listener(port: port, proto: proto, exposed: prev.exposed || exposed)
            } else {
                found[key] = Listener(port: port, proto: proto, exposed: exposed)
            }
        }
        return found.values.sorted { ($0.proto.rawValue, $0.port) < ($1.proto.rawValue, $1.port) }
    }

    private static func isExposed(_ ini: in_sockinfo) -> Bool {
        if ini.insi_vflag & UInt8(INI_IPV4) != 0 {
            let a = UInt32(bigEndian: ini.insi_laddr.ina_46.i46a_addr4.s_addr)
            return (a >> 24) != 127
        }
        var a6 = ini.insi_laddr.ina_6
        let bytes = withUnsafeBytes(of: &a6) { Array($0) }
        let loopback = bytes[0..<15].allSatisfy { $0 == 0 } && bytes[15] == 1
        return !loopback
    }

    static func string<T>(fromTuple t: T) -> String {
        var t = t
        return withUnsafeBytes(of: &t) { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let end = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: bytes[0..<end], as: UTF8.self)
        }
    }
}
