import AppKit
import SwiftUI

/// Pestaña "Worktrees": estado de cada worktree de git y limpieza de los ya fusionados.
struct WorktreesSection: View {
    @EnvironmentObject private var m: Monitor
    @EnvironmentObject private var wt: WorktreeService
    @EnvironmentObject private var an: DiskAnalyzer
    @State private var oldestFirst = false
    @State private var confirmCandidates = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if wt.worktrees.isEmpty {
                if wt.loading {
                    HStack { ProgressView().controlSize(.small); Text("Leyendo repositorios…").font(.callout).foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity).padding(.vertical, 14).card()
                } else {
                    Text("No hay repos con worktrees en ~/Documents/projects.").font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 14).card()
                }
            } else {
                candidatesCard
                ForEach(wt.repos, id: \.self) { repo in repoSection(repo) }
            }
        }
        .onAppear { wt.refreshIfStale() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Worktrees").font(.system(size: 13, weight: .semibold))
                let n = wt.worktrees.filter { !$0.isMain }.count
                Text("\(n) worktree\(n == 1 ? "" : "s") en \(wt.repos.count) repo\(wt.repos.count == 1 ? "" : "s")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $oldestFirst) {
                Text("Recientes").tag(false)
                Text("Antiguos").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if wt.loading || wt.fetching {
                ProgressView().controlSize(.small).frame(width: 22)
            } else {
                Menu {
                    Button("Volver a leer") { wt.refresh() }
                    Button("Actualizar desde el remoto (git fetch --prune)") { wt.fetchAll() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Actualizar. «git fetch --prune» detecta las ramas ya fusionadas y borradas en GitHub.")
            }
        }
    }

    // MARK: Candidatos

    @ViewBuilder
    private var candidatesCard: some View {
        let c = wt.worktrees.filter { $0.isCandidate && !isRunning($0) }
        if !c.isEmpty {
            let size = c.compactMap { an.report?.worktreeSizes[$0.path] }.reduce(0, +)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Listos para eliminar", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Severity.ok.color)
                    Spacer()
                    if size > 0 { Text("ocupan \(Fmt.disk(size))").font(.caption).foregroundStyle(.secondary) }
                }
                Text("\(c.count) worktree\(c.count == 1 ? "" : "s") sin cambios cuya rama ya está fusionada o borrada en el remoto: \(c.prefix(4).map(\.name).joined(separator: ", "))\(c.count > 4 ? "…" : ".")")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if confirmCandidates {
                    HStack {
                        Text("Se eliminan los \(c.count) worktrees y sus ramas locales.").font(.caption)
                        Spacer()
                        Button("No") { confirmCandidates = false }.controlSize(.small)
                        Button("Eliminar") { confirmCandidates = false; wt.remove(c, force: false, deleteBranch: true) }
                            .controlSize(.small).buttonStyle(.borderedProminent).tint(Severity.critical.color)
                    }
                } else {
                    Button { confirmCandidates = true } label: {
                        Label("Eliminar los \(c.count)\(size > 0 ? " · libera \(Fmt.disk(size))" : "")", systemImage: "trash").frame(maxWidth: .infinity)
                    }
                    .controlSize(.small)
                }
            }
            .card()
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Severity.ok.color.opacity(0.35), lineWidth: 1))
        }
    }

    // MARK: Lista

    private func repoSection(_ repo: String) -> some View {
        let list = wt.worktrees.filter { $0.repo == repo }.sorted { a, b in
            if a.isMain != b.isMain { return a.isMain }
            let x = a.lastCommit ?? .distantPast, y = b.lastCommit ?? .distantPast
            return oldestFirst ? x < y : x > y
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10)).foregroundStyle(.secondary)
                Text((repo as NSString).lastPathComponent).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                let total = list.compactMap { an.report?.worktreeSizes[$0.path] }.reduce(0, +)
                if total > 0 { Text(Fmt.disk(total)).font(.caption).foregroundStyle(.tertiary) }
            }
            VStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, w in
                    if i > 0 { Divider().opacity(0.4) }
                    WorktreeRow(wt: w, running: isRunning(w), size: an.report?.worktreeSizes[w.path])
                }
            }
            .card(padding: 8)
        }
    }

    private func isRunning(_ w: Worktree) -> Bool {
        m.groups.contains { g in g.path.map { $0 == w.path || $0.hasPrefix(w.path + "/") } == true }
    }
}

private struct WorktreeRow: View {
    @EnvironmentObject private var svc: WorktreeService
    var wt: Worktree
    var running: Bool
    var size: UInt64?
    @State private var hover = false
    @State private var confirming = false
    @State private var deleteBranch = true

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(wt.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        badges
                    }
                    Text(wt.branch ?? (wt.detached ? "HEAD separado" : "—"))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(size.map(Fmt.disk) ?? "").font(.system(size: 11)).monospacedDigit()
                    if let d = wt.lastCommit { Text(Fmt.relative(d)).font(.system(size: 9.5)).foregroundStyle(.secondary) }
                }
                if svc.busy.contains(wt.path) {
                    ProgressView().controlSize(.small).frame(width: 44)
                } else {
                    MoreMenu(visible: hover, help: "Abrir \(wt.name) en…") { OpenInMenuItems(path: wt.path) }
                    IconButton(symbol: "trash", help: deleteHelp, color: hover && canDelete ? .secondary : .clear) {
                        if canDelete { deleteBranch = wt.merged || wt.upstreamGone; confirming = true }
                    }
                }
            }
            if confirming { confirmView }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .help(wt.subject.isEmpty ? wt.path : "Último commit: \(wt.subject)")
        .contextMenu { OpenInMenuItems(path: wt.path) }
    }

    @ViewBuilder
    private var badges: some View {
        if wt.isMain { badge("principal", .secondary) }
        if running { badge("en marcha", GroupKind.project.tint) }
        if wt.changes > 0 { badge("\(wt.changes) cambio\(wt.changes == 1 ? "" : "s")", Severity.warn.color) }
        if wt.fresh && !wt.isMain { badge("sin commits propios", .secondary) }
        else if wt.merged { badge("fusionada", Severity.ok.color) }
        else if wt.upstreamGone { badge("borrada en remoto", Severity.ok.color) }
        if wt.ahead > 0 || wt.behind > 0 {
            badge([wt.ahead > 0 ? "↑\(wt.ahead)" : nil, wt.behind > 0 ? "↓\(wt.behind)" : nil].compactMap { $0 }.joined(separator: " "), .secondary)
        }
    }

    private func badge(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(c.opacity(0.16)))
            .foregroundStyle(c)
            .fixedSize()
    }

    private var canDelete: Bool { !wt.isMain && !running }
    private var deleteHelp: String {
        if wt.isMain { return "Es el repositorio principal" }
        if running { return "Tiene procesos en marcha: ciérralos primero" }
        return "Eliminar worktree"
    }

    private var confirmView: some View {
        VStack(alignment: .leading, spacing: 6) {
            if wt.changes > 0 {
                Label("Tiene \(wt.changes) cambio\(wt.changes == 1 ? "" : "s") sin commitear: se perderán.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Severity.critical.color)
            } else if !(wt.merged || wt.upstreamGone) {
                Label("La rama no está fusionada. Sus commits seguirán en la rama si no la borras.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if wt.branch != nil {
                Toggle("Borrar también la rama \(wt.branch ?? "")", isOn: $deleteBranch)
                    .toggleStyle(.checkbox).font(.caption)
            }
            HStack {
                Spacer()
                Button("Cancelar") { confirming = false }.controlSize(.small)
                Button(wt.changes > 0 ? "Eliminar igualmente" : "Eliminar") {
                    confirming = false
                    svc.remove([wt], force: wt.changes > 0, deleteBranch: deleteBranch)
                }
                .controlSize(.small).buttonStyle(.borderedProminent).tint(Severity.critical.color)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Severity.critical.color.opacity(0.08)))
    }
}
