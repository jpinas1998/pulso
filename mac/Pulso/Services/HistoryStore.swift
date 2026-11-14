import Foundation

struct HistoryPoint: Identifiable {
    var t: Date
    var cpu: Double
    var mem: Double
    var swap: UInt64
    var diskFree: UInt64
    var pressure: Int
    var id: Date { t }
    var swapValue: Double { Double(swap) }
    var diskFreeValue: Double { Double(diskFree) }
}

/// Historial de 30 días en un CSV pequeño (una línea cada 5 minutos ≈ 300 KB al mes).
final class HistoryStore {
    private(set) var points: [HistoryPoint] = []
    private let retention: TimeInterval = 30 * 86400
    private var lastCompaction = Date()

    init() { load() }

    func append(_ p: HistoryPoint) {
        points.append(p)
        let line = String(format: "%.0f,%.4f,%.4f,%llu,%llu,%d\n", p.t.timeIntervalSince1970, p.cpu, p.mem, p.swap, p.diskFree, p.pressure)
        if let h = try? FileHandle(forWritingTo: AppPaths.history) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: AppPaths.history)
        }
        if Date().timeIntervalSince(lastCompaction) > 86400 { compact() }
    }

    func points(last interval: TimeInterval) -> [HistoryPoint] {
        let from = Date().addingTimeInterval(-interval)
        return points.filter { $0.t >= from }
    }

    /// Reduce puntos para pintar gráficas (media por cubo de tiempo).
    func downsampled(last interval: TimeInterval, buckets: Int) -> [HistoryPoint] {
        let src = points(last: interval)
        guard src.count > buckets, let first = src.first?.t else { return src }
        let width = interval / Double(buckets)
        var out: [HistoryPoint] = []
        var bucket: [HistoryPoint] = []
        var edge = first.addingTimeInterval(width)
        for p in src {
            if p.t >= edge, !bucket.isEmpty {
                out.append(average(bucket))
                bucket = []
                while p.t >= edge { edge = edge.addingTimeInterval(width) }
            }
            bucket.append(p)
        }
        if !bucket.isEmpty { out.append(average(bucket)) }
        return out
    }

    private func average(_ b: [HistoryPoint]) -> HistoryPoint {
        let n = Double(b.count)
        return HistoryPoint(t: b[b.count / 2].t,
                            cpu: b.map(\.cpu).reduce(0, +) / n,
                            mem: b.map(\.mem).reduce(0, +) / n,
                            swap: UInt64(b.map { Double($0.swap) }.reduce(0, +) / n),
                            diskFree: b.last!.diskFree,
                            pressure: b.map(\.pressure).max() ?? 1)
    }

    private func load() {
        guard let text = try? String(contentsOf: AppPaths.history, encoding: .utf8) else { return }
        let from = Date().addingTimeInterval(-retention).timeIntervalSince1970
        points = text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: ",")
            guard f.count == 6, let t = Double(f[0]), t >= from else { return nil }
            return HistoryPoint(t: Date(timeIntervalSince1970: t), cpu: Double(f[1]) ?? 0, mem: Double(f[2]) ?? 0,
                                swap: UInt64(f[3]) ?? 0, diskFree: UInt64(f[4]) ?? 0, pressure: Int(f[5]) ?? 1)
        }
        compact()
    }

    private func compact() {
        lastCompaction = Date()
        let from = Date().addingTimeInterval(-retention)
        points.removeAll { $0.t < from }
        let text = points.map {
            String(format: "%.0f,%.4f,%.4f,%llu,%llu,%d", $0.t.timeIntervalSince1970, $0.cpu, $0.mem, $0.swap, $0.diskFree, $0.pressure)
        }.joined(separator: "\n") + (points.isEmpty ? "" : "\n")
        try? Data(text.utf8).write(to: AppPaths.history, options: .atomic)
    }
}
