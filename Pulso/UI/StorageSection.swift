import AppKit
import SwiftUI

/// Pestaña "Espacio": qué ocupa el disco en desarrollo y qué se puede borrar sin miedo.
struct StorageSection: View {
    @EnvironmentObject private var m: Monitor
    @EnvironmentObject private var an: DiskAnalyzer
    @EnvironmentObject private var cleanup: CleanupService

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let r = an.report {
                summary(r)
                projects(r)
                globals(r)
                if !r.fvm.isEmpty { fvm(r) }
            } else if !an.running {
                Text("Analiza el disco para ver cuánto ocupan los builds, entornos de Python, cachés de Gradle, Xcode, Android y demás. No se borra nada sin preguntarte.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .card()
            }
        }
    }

    // MARK: Cabecera

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Espacio recuperable").font(.system(size: 13, weight: .semibold))
                if an.running {
                    Text(an.progress).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                } else if let r = an.report {
                    Text("Analizado \(Fmt.relative(r.date))").font(.caption2).foregroundStyle(.tertiary)
                        .help("El análisis tarda unos minutos y va con prioridad baja")
                }
            }
            Spacer()
            if an.running {
                ProgressView().controlSize(.small)
                Button("Cancelar") { an.cancel() }.controlSize(.small)
            } else {
                Button { an.analyze() } label: { Label(an.report == nil ? "Analizar" : "Volver a analizar", systemImage: "magnifyingglass") }
                    .controlSize(.small)
            }
        }
    }

    // MARK: Resumen

    private func summary(_ r: DiskReport) -> some View {
        let proj = r.artifacts.filter { !isRunning($0) }.reduce(0) { $0 + $1.bytes }
        let glob = r.globals.filter { GlobalInfo.of($0.kind).deletable }.reduce(0) { $0 + $1.bytes }
        let fv = r.fvm.filter { !$0.inUse }.reduce(0) { $0 + $1.bytes }
        let script = cleanup.state.measurement?.total ?? 0
        let total = proj + glob + fv + script
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("~\(Fmt.disk(total))").font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("se pueden recuperar").font(.callout).foregroundStyle(.secondary)
            }
            SegmentBar(segments: [(Double(proj), Palette.app), (Double(glob), Palette.compressed),
                                  (Double(fv), Palette.cached), (Double(script), Palette.wired)], height: 8)
            HStack(spacing: 10) {
                legend(Palette.app, "Proyectos", proj)
                legend(Palette.compressed, "Cachés", glob)
                if fv > 0 { legend(Palette.cached, "Flutter", fv) }
                if script > 0 { legend(Palette.wired, "Script", script) }
            }
        }
        .card()
    }

    private func legend(_ c: Color, _ t: String, _ b: UInt64) -> some View {
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 6, height: 6)
            Text("\(t) \(Fmt.disk(b))").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    // MARK: Proyectos

    private func projects(_ r: DiskReport) -> some View {
        let kinds = ArtifactInfo.order.filter { k in r.artifacts.contains { $0.kind == k && $0.bytes > 1_000_000 } }
        return VStack(alignment: .leading, spacing: 8) {
            Text("En tus proyectos").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(kinds, id: \.self) { k in
                ArtifactKindCard(kind: k, items: r.artifacts.filter { $0.kind == k && $0.bytes > 1_000_000 }.sorted { $0.bytes > $1.bytes })
            }
        }
    }

    // MARK: Cachés

    private func globals(_ r: DiskReport) -> some View {
        let items = r.globals.filter { $0.bytes > 50_000_000 }.sorted {
            let a = GlobalInfo.of($0.kind).deletable, b = GlobalInfo.of($1.kind).deletable
            return a != b ? a : $0.bytes > $1.bytes
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Cachés de herramientas").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    if i > 0 { Divider().opacity(0.5) }
                    GlobalRow(item: item)
                }
            }
            .card(padding: 8)
        }
    }

    private func fvm(_ r: DiskReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Versiones de Flutter (fvm)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(r.fvm.sorted { $0.kind > $1.kind }.enumerated()), id: \.element.id) { i, item in
                    if i > 0 { Divider().opacity(0.5) }
                    FVMRow(item: item)
                }
            }
            .card(padding: 8)
        }
    }

    private func isRunning(_ item: DiskItem) -> Bool {
        m.groups.contains { g in g.kind == .project && g.path.map { item.path.hasPrefix($0 + "/") } == true }
    }
}

// MARK: - Tarjeta por tipo de artefacto

private struct ArtifactKindCard: View {
    @EnvironmentObject private var m: Monitor
    @EnvironmentObject private var an: DiskAnalyzer
    var kind: String
    var items: [DiskItem]
    @State private var expanded = false
    @State private var confirmStale = false

    var body: some View {
        let info = ArtifactInfo.of(kind)
        let total = items.reduce(0) { $0 + $1.bytes }
        let stale = items.filter { isStale($0) && !isRunning($0) }
        let staleBytes = stale.reduce(0) { $0 + $1.bytes }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: info.symbol).font(.system(size: 11)).foregroundStyle(Palette.app)
                    .frame(width: 22, height: 22).background(RoundedRectangle(cornerRadius: 6).fill(Palette.app.opacity(0.14)))
                VStack(alignment: .leading, spacing: 0) {
                    Text(info.label).font(.system(size: 12.5, weight: .semibold))
                    Text("\(items.count) carpeta\(items.count == 1 ? "" : "s") · \(info.regen)")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 4)
                Text(Fmt.disk(total)).font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } }
            .help(info.regen)

            if !stale.isEmpty {
                if confirmStale {
                    HStack(spacing: 6) {
                        Text("¿Borrar \(stale.count) carpeta\(stale.count == 1 ? "" : "s")? \(info.regen)").font(.caption).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("No") { confirmStale = false }.controlSize(.small)
                        Button("Borrar") { confirmStale = false; an.delete(stale) }
                            .controlSize(.small).buttonStyle(.borderedProminent).tint(Severity.critical.color)
                    }
                } else {
                    Button { confirmStale = true } label: {
                        Label("Borrar \(stale.count) sin usar en \(Int(DiskAnalyzer.staleDays)) días · \(Fmt.disk(staleBytes))", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.small)
                }
            }

            if expanded {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        if i > 0 { Divider().opacity(0.4) }
                        ArtifactRow(item: item, running: isRunning(item))
                    }
                }
            }
        }
        .card()
    }

    private func isStale(_ i: DiskItem) -> Bool {
        guard let d = i.mtime else { return false }
        return Date().timeIntervalSince(d) > DiskAnalyzer.staleDays * 86400
    }

    private func isRunning(_ item: DiskItem) -> Bool {
        m.groups.contains { g in g.kind == .project && g.path.map { item.path.hasPrefix($0 + "/") } == true }
    }
}

private struct ArtifactRow: View {
    @EnvironmentObject private var an: DiskAnalyzer
    var item: DiskItem
    var running: Bool
    @State private var hover = false
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(item.shortPath).font(.system(size: 11.5, weight: .medium)).lineLimit(1).truncationMode(.head)
                Group {
                    if running { Text("proyecto en marcha").foregroundStyle(Severity.ok.color) }
                    else if let d = item.mtime { Text("usado \(Fmt.relative(d))") }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Fmt.disk(item.bytes)).font(.system(size: 11)).monospacedDigit()
            if an.deleting.contains(item.path) {
                ProgressView().controlSize(.small).frame(width: 22)
            } else if confirming {
                Button("Borrar") { confirming = false; an.delete([item]) }
                    .controlSize(.mini).buttonStyle(.borderedProminent).tint(Severity.critical.color)
                Button("No") { confirming = false }.controlSize(.mini)
            } else {
                IconButton(symbol: "folder", help: "Mostrar en Finder", color: hover ? .secondary : .clear) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                }
                IconButton(symbol: "trash", help: running ? "El proyecto está en marcha" : "Borrar", color: hover && !running ? .secondary : .clear) {
                    if !running { confirming = true }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .help(item.path)
    }
}

// MARK: - Cachés y fvm

private struct GlobalRow: View {
    @EnvironmentObject private var an: DiskAnalyzer
    var item: DiskItem
    @State private var confirming = false

    var body: some View {
        let info = GlobalInfo.of(item.kind)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(info.label).font(.system(size: 12, weight: .medium))
                    Text(info.help).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Text(Fmt.disk(item.bytes)).font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                if an.deleting.contains(item.path) {
                    ProgressView().controlSize(.small).frame(width: 60)
                } else if info.deletable {
                    Button("Borrar") { confirming = true }.controlSize(.small).frame(width: 60)
                } else {
                    Button("Ver") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
                        .controlSize(.small).frame(width: 60)
                }
            }
            if confirming {
                HStack {
                    Text("¿Borrar \(info.label.lowercased()) (\(Fmt.disk(item.bytes)))?").font(.caption)
                    Spacer()
                    Button("No") { confirming = false }.controlSize(.mini)
                    Button("Borrar") { confirming = false; an.delete([item], isGlobal: true) }
                        .controlSize(.mini).buttonStyle(.borderedProminent).tint(Severity.critical.color)
                }
            }
        }
        .padding(.vertical, 5)
        .help(item.path)
    }
}

private struct FVMRow: View {
    @EnvironmentObject private var an: DiskAnalyzer
    var item: DiskItem
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bird.fill").font(.system(size: 11)).foregroundStyle(Palette.cached)
            Text("Flutter \(item.kind)").font(.system(size: 12, weight: .medium))
            if item.inUse {
                Text("en uso").font(.system(size: 9, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Severity.ok.color.opacity(0.18))).foregroundStyle(Severity.ok.color)
            }
            Spacer()
            Text(Fmt.disk(item.bytes)).font(.system(size: 11.5)).monospacedDigit()
            if an.deleting.contains(item.path) {
                ProgressView().controlSize(.small).frame(width: 60)
            } else if confirming {
                Button("Borrar") { confirming = false; an.delete([item], isFVM: true) }
                    .controlSize(.mini).buttonStyle(.borderedProminent).tint(Severity.critical.color)
                Button("No") { confirming = false }.controlSize(.mini)
            } else {
                Button("Borrar") { confirming = true }.controlSize(.small).disabled(item.inUse).frame(width: 60)
                    .help(item.inUse ? "La usa algún proyecto o es la versión global" : "Ningún proyecto la usa")
            }
        }
        .padding(.vertical, 4)
    }
}
