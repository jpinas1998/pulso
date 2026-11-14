import Darwin
import Foundation

// Lecturas del sistema directamente con las APIs de Mach/sysctl (sin lanzar procesos).

struct CPUTicks {
    var user: UInt32 = 0, system: UInt32 = 0, idle: UInt32 = 0, nice: UInt32 = 0
}

struct CPUUsage {
    var total: Double = 0
    var user: Double = 0
    var system: Double = 0

    /// Uso entre dos lecturas. La resta con desbordamiento (&-) cubre el caso de que el contador dé la vuelta.
    init(from a: CPUTicks, to b: CPUTicks) {
        let u = Double(b.user &- a.user), s = Double(b.system &- a.system)
        let n = Double(b.nice &- a.nice), i = Double(b.idle &- a.idle)
        let all = u + s + n + i
        guard all > 0 else { return }
        user = (u + n) / all
        system = s / all
        total = user + system
    }

    init() {}
}

struct MemoryStats {
    var total: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var swapTotal: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressure: PressureLevel = .normal
    var swapIns: UInt64 = 0
    var swapOuts: UInt64 = 0

    var used: UInt64 { app + wired + compressed }
    var free: UInt64 { total > used + cached ? total - used - cached : 0 }
    var available: UInt64 { total > used ? total - used : 0 }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

struct DiskStats {
    var total: UInt64 = 0
    var available: UInt64 = 0
    var used: UInt64 { total > available ? total - available : 0 }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

enum SystemSampler {
    private static let host = mach_host_self()

    static let physicalMemory: UInt64 = {
        var v: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &v, &size, nil, 0)
        return v
    }()

    static let coreCount = ProcessInfo.processInfo.activeProcessorCount

    static func cpuTicks() -> CPUTicks {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return CPUTicks() }
        let t = info.cpu_ticks
        return CPUTicks(user: t.0, system: t.1, idle: t.2, nice: t.3)
    }

    static func memory() -> MemoryStats {
        var m = MemoryStats()
        m.total = physicalMemory

        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if r == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let internalPages = UInt64(vm.internal_page_count)
            let purgeable = UInt64(vm.purgeable_count)
            // Mismas fórmulas que el Monitor de Actividad.
            m.app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
            m.wired = UInt64(vm.wire_count) * page
            m.compressed = UInt64(vm.compressor_page_count) * page
            m.cached = (UInt64(vm.external_page_count) + purgeable) * page
            m.swapIns = vm.swapins
            m.swapOuts = vm.swapouts
        }

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            m.swapTotal = swap.xsu_total
            m.swapUsed = swap.xsu_used
        }

        var level: Int32 = 1
        size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            m.pressure = PressureLevel(raw: level)
        }
        return m
    }

    static func disk() -> DiskStats {
        let url = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return DiskStats() }
        let total = UInt64(v.volumeTotalCapacity ?? 0)
        // "Important usage" incluye el espacio purgable, igual que el Finder.
        let avail = v.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
            ?? UInt64(v.volumeAvailableCapacity ?? 0)
        return DiskStats(total: total, available: avail)
    }

    static func loadAverage() -> [Double] {
        var l = [Double](repeating: 0, count: 3)
        getloadavg(&l, 3)
        return l
    }
}
