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
            Text("Pulso").font(.system(size: 11, weight: .semibold, design: .rounded))
            Spacer(minLength: 2)
            if Date().timeIntervalSince(s.date) > 20 * 60 {
                Label("sin datos recientes", systemImage: "exclamationmark.circle").font(.system(size: 9)).foregroundStyle(.orange)
            } else {
                Text(Fmt.time(s.date)).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
    }
}

private struct MiniBar: View {
    var fraction: Double
    var color: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(color).frame(width: max(3, g.size.width * min(1, fraction)))
            }
        }
        .frame(height: 3)
    }
}

private struct Metric: View {
    var title: String
    var value: String
    var fraction: Double
    var severity: Severity

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text(value).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            MiniBar(fraction: fraction, color: severity.color)
        }
    }
}

private struct Metrics: View {
    var s: WidgetSnapshot

    var body: some View {
        VStack(spacing: 7) {
            Metric(title: "CPU", value: Fmt.pct(s.cpu), fraction: s.cpu, severity: .forCPU(s.cpu))
            Metric(title: "Memoria", value: Fmt.pct(s.memFraction), fraction: s.memFraction, severity: s.pressure.severity)
            Metric(title: "Disco libre", value: Fmt.disk(s.diskFree), fraction: s.diskUsedFraction,
                   severity: .forDisk(free: s.diskFree, total: s.diskTotal))
        }
    }
}

struct SmallView: View {
    var s: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Header(s: s)
            Metrics(s: s)
            Spacer(minLength: 0)
            let ports = s.groups.reduce(0) { $0 + $1.ports.count }
            HStack(spacing: 4) {
                Circle().fill(ports > 0 ? Severity.ok.color : Color.secondary).frame(width: 5, height: 5)
                Text("\(ports) puerto\(ports == 1 ? "" : "s")").font(.system(size: 9.5)).foregroundStyle(.secondary)
                Spacer(minLength: 2)
                if let r = s.cleanup.reclaimable, r > 500_000_000 {
                    Text("~\(Fmt.disk(r))").font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ServerRow: View {
    var g: WidgetGroup
    var closable = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(g.kind.tint).frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 0) {
                Text(g.name).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                Text(g.ports.isEmpty ? "sin puertos" : g.ports.prefix(5).map { ":\($0)" }.joined(separator: " "))
                    .font(.system(size: 8.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 2)
            Text(Fmt.mem(g.ram)).font(.system(size: 9.5)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            if closable, g.kind != .system, let url = closeURL {
                Link(destination: url) {
                    Image(systemName: "stop.circle").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var closeURL: URL? {
        var c = URLComponents()
        c.scheme = PulsoShared.urlScheme
        c.host = "close-group"
        c.queryItems = [URLQueryItem(name: "id", value: g.id)]
        return c.url
    }
}

/// Lista de servidores que muestra tantas filas como quepan (5, 4, 3…), sin cortarse nunca.
private struct ServerList: View {
    var groups: [WidgetGroup]
    var closable = false
    var maxRows = 5

    var body: some View {
        if groups.isEmpty {
            Text("Nada escuchando").font(.system(size: 10)).foregroundStyle(.tertiary)
        } else {
            ViewThatFits(in: .vertical) {
                ForEach((1...maxRows).reversed(), id: \.self) { n in rows(n) }
            }
        }
    }

    private func rows(_ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(groups.prefix(n)) { ServerRow(g: $0, closable: closable) }
            if groups.count > n {
                Text("+\(groups.count - n) más").font(.system(size: 8.5)).foregroundStyle(.tertiary)
            }
        }
    }
}

struct MediumView: View {
    var s: WidgetSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Header(s: s)
                Metrics(s: s)
                Spacer(minLength: 0)
            }
            .frame(width: 118)

            VStack(alignment: .leading, spacing: 5) {
                Text("Servidores").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                ServerList(groups: s.groups, maxRows: 4)
                Spacer(minLength: 0)
            }
        }
    }
}

struct LargeView: View {
    var s: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Header(s: s)
            HStack(alignment: .top, spacing: 7) {
                WTile(title: "CPU", value: Fmt.pct(s.cpu), fraction: s.cpu, severity: .forCPU(s.cpu))
                WTile(title: "Memoria", value: Fmt.pct(s.memFraction), fraction: s.memFraction, severity: s.pressure.severity)
                WTile(title: "Disco", value: Fmt.disk(s.diskFree), fraction: s.diskUsedFraction,
                      severity: .forDisk(free: s.diskFree, total: s.diskTotal))
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Servidores").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                ServerList(groups: s.groups, closable: true, maxRows: 6)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            cleanup
        }
    }

    private var cleanup: some View {
        HStack(spacing: 7) {
            Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(s.cleanup.reclaimable.map { "~\(Fmt.disk($0)) liberables" } ?? "Espacio sin medir")
                    .font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                Text(cleanupCaption).font(.system(size: 8.5)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
            }
            Spacer(minLength: 4)
            Link(destination: URL(string: "pulso://measure")!) {
                Text("Medir").font(.system(size: 9.5, weight: .medium))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
            }
            Link(destination: URL(string: "pulso://clean")!) {
                Text("Limpiar").font(.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.22)))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))
    }

    private var cleanupCaption: String {
        if let st = s.cleanup.status { return st }
        if let n = s.cleanup.nextRun { return "Próxima medición \(Fmt.relative(n))" }
        if let m = s.cleanup.measuredAt { return "Medido \(Fmt.relative(m))" }
        return ""
    }
}

private struct WTile: View {
    var title: String
    var value: String
    var fraction: Double
    var severity: Severity

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle().fill(severity.color).frame(width: 5, height: 5)
                Text(title).font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            MiniBar(fraction: fraction, color: severity.color)
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))
    }
}
