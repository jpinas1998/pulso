import SwiftUI
import WidgetKit

// Widget de escritorio. Lee la instantánea que escribe la app (App Group) y la pinta.
// macOS decide cuándo refrescarlo; la app lo pide en cada lectura completa (cada 5 min).

struct PulsoEntry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> PulsoEntry { PulsoEntry(date: Date(), snap: .sample) }

    func getSnapshot(in context: Context, completion: @escaping (PulsoEntry) -> Void) {
        completion(PulsoEntry(date: Date(), snap: WidgetSnapshot.load() ?? (context.isPreview ? .sample : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PulsoEntry>) -> Void) {
        let entry = PulsoEntry(date: Date(), snap: WidgetSnapshot.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(300))))
    }
}

#if !PULSO_SNAPSHOT
@main
#endif
struct PulsoWidgetBundle: WidgetBundle {
    var body: some Widget { PulsoWidget() }
}

struct PulsoWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: PulsoShared.widgetKind, provider: Provider()) { entry in
            WidgetRoot(entry: entry)
                .containerBackground(for: .widget) { Color.clear.background(.background) }
                .widgetURL(URL(string: "pulso://open"))
        }
        .configurationDisplayName("Pulso")
        .description("CPU, memoria, disco, tus servidores y el espacio que puedes liberar.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Vistas

struct WidgetRoot: View {
    @Environment(\.widgetFamily) private var family
    var entry: PulsoEntry

    var body: some View {
        if let s = entry.snap {
            switch family {
            case .systemSmall: SmallView(s: s)
            case .systemMedium: MediumView(s: s)
            default: LargeView(s: s)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.33percent").font(.title2).foregroundStyle(.secondary)
                Text("Abre Pulso para empezar").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct Header: View {
    var s: WidgetSnapshot

    var body: some View {
        HStack(spacing: 4) {
            Text("Pulso").font(.system(size: 12, weight: .semibold, design: .rounded))
            Spacer(minLength: 2)
            if Date().timeIntervalSince(s.date) > 20 * 60 {
                Label("sin datos recientes", systemImage: "exclamationmark.circle").font(.system(size: 9)).foregroundStyle(.orange)
            } else {
                Text(Fmt.time(s.date)).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
    }
}

private struct Metric: View {
    var title: String
    var value: String
    var fraction: Double
    var severity: Severity
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: compact ? 10 : 11)).foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text(value).font(.system(size: compact ? 12 : 14, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(severity.color).frame(width: max(4, g.size.width * min(1, fraction)))
                }
            }
            .frame(height: 4)
        }
    }
}

private struct Metrics: View {
    var s: WidgetSnapshot
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 7 : 9) {
            Metric(title: "CPU", value: Fmt.pct(s.cpu), fraction: s.cpu, severity: .forCPU(s.cpu), compact: compact)
            Metric(title: "Memoria", value: Fmt.pct(s.memFraction), fraction: s.memFraction, severity: s.pressure.severity, compact: compact)
            Metric(title: "Disco libre", value: Fmt.disk(s.diskFree), fraction: s.diskUsedFraction,
                   severity: .forDisk(free: s.diskFree, total: s.diskTotal), compact: compact)
        }
    }
}

struct SmallView: View {
    var s: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Header(s: s)
            Metrics(s: s, compact: true)
            Spacer(minLength: 0)
            footer
        }
    }

    private var footer: some View {
        let ports = s.groups.reduce(0) { $0 + $1.ports.count }
        return HStack(spacing: 4) {
            Circle().fill(ports > 0 ? Severity.ok.color : Color.secondary).frame(width: 5, height: 5)
            Text("\(ports) puerto\(ports == 1 ? "" : "s")").font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
            if let r = s.cleanup.reclaimable, r > 500_000_000 {
                Text("~\(Fmt.disk(r))").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ServerRow: View {
    var g: WidgetGroup
    var closable = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(g.kind.tint).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 0) {
                Text(g.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text(g.ports.isEmpty ? "sin puertos" : g.ports.prefix(5).map { ":\($0)" }.joined(separator: " "))
                    .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 2)
            Text(Fmt.mem(g.ram)).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            if closable, g.kind != .system, let url = closeURL {
                Link(destination: url) {
                    Image(systemName: "stop.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var closeURL: URL? {
        var c = URLComponents()
        c.scheme = PulsoShared.urlScheme
        c.host = "close-group"
        c.queryItems = [URLQueryItem(name: "id", value: g.id)]
        return c.url
    }
}

struct MediumView: View {
    var s: WidgetSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Header(s: s)
                Metrics(s: s, compact: true)
            }
            .frame(width: 128)

            VStack(alignment: .leading, spacing: 6) {
                Text("Servidores").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                if s.groups.isEmpty {
                    Text("Nada escuchando").font(.caption).foregroundStyle(.tertiary)
                } else {
                    ForEach(s.groups.prefix(4)) { ServerRow(g: $0) }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct LargeView: View {
    var s: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Header(s: s)
            HStack(alignment: .top, spacing: 10) {
                WTile(title: "CPU", value: Fmt.pct(s.cpu), fraction: s.cpu, severity: .forCPU(s.cpu), caption: "uso total")
                WTile(title: "Memoria", value: Fmt.pct(s.memFraction), fraction: s.memFraction, severity: s.pressure.severity,
                     caption: "presión \(s.pressure.label.lowercased())")
                WTile(title: "Disco", value: Fmt.disk(s.diskFree), fraction: s.diskUsedFraction,
                     severity: .forDisk(free: s.diskFree, total: s.diskTotal), caption: "libres")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Servidores").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                if s.groups.isEmpty {
                    Text("Nada escuchando").font(.caption).foregroundStyle(.tertiary)
                } else {
                    ForEach(s.groups.prefix(5)) { ServerRow(g: $0, closable: true) }
                }
            }
            Spacer(minLength: 0)
            cleanup
        }
    }

    private var cleanup: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                if let r = s.cleanup.reclaimable {
                    Text("~\(Fmt.disk(r)) liberables").font(.system(size: 12, weight: .semibold))
                } else {
                    Text("Espacio liberable sin medir").font(.system(size: 12, weight: .semibold))
                }
                Text(cleanupCaption).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Link(destination: URL(string: "pulso://measure")!) {
                Text("Medir").font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            Link(destination: URL(string: "pulso://clean")!) {
                Text("Limpiar").font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.2)))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private var cleanupCaption: String {
        if let st = s.cleanup.status { return st }
        if let n = s.cleanup.nextRun { return "Próxima medición: \(Fmt.time(n))" }
        if let m = s.cleanup.measuredAt { return "Medido \(Fmt.relative(m))" }
        return ""
    }
}

private struct WTile: View {
    var title: String
    var value: String
    var fraction: Double
    var severity: Severity
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle().fill(severity.color).frame(width: 5, height: 5)
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(severity.color).frame(width: max(4, g.size.width * min(1, fraction)))
                }
            }
            .frame(height: 4)
            if let caption { Text(caption).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1) }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}
