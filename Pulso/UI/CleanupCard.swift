import SwiftUI

struct CleanupCard: View {
    @EnvironmentObject private var cleanup: CleanupService
    @State private var confirmClean = false
    @State private var confirmVolumes = false
    @State private var showLog = false
    @State private var showAllRuns = false
    @AppStorage(Prefs.Key.idleAvgCPU) private var idleAvg = 30
    @AppStorage(Prefs.Key.idleNowCPU) private var idleNow = 40
    @AppStorage(Prefs.Key.idleWindowMinutes) private var window = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            estimate
            if let job = cleanup.running { runningView(job) } else { actions }
            Divider()
            schedule
            runs
        }
        .card()
    }

    // MARK: Estimación

    @ViewBuilder
    private var estimate: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Limpieza").font(.system(size: 13, weight: .semibold))
            Spacer()
            if let m = cleanup.state.measurement, !m.isClean {
                Text("medido \(Fmt.relative(m.date))").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        if let m = cleanup.state.measurement, m.isClean {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Severity.ok.color)
                    Text("Limpio").font(.system(size: 20, weight: .semibold, design: .rounded))
                    if let f = m.freed, f > 0 {
                        Text("liberados ~\(Fmt.disk(f)) \(Fmt.relative(m.cleanedAt ?? m.date))").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Text("No queda nada que este script pueda borrar. Se volverá a medir cuando el Mac esté tranquilo; si quieres ver más espacio recuperable, mira la pestaña Espacio.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } else if let m = cleanup.state.measurement {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("~\(Fmt.disk(m.total))").font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("se pueden liberar").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(m.items.filter { $0.bytes > 0 && $0.key != "docker_volumenes" }.sorted { $0.bytes > $1.bytes }) { item in
                    HStack {
                        Text(item.label).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(Fmt.disk(item.bytes)).font(.caption).monospacedDigit()
                    }
                }
                if m.volumes > 0 {
                    Text("+ \(Fmt.disk(m.volumes)) en volúmenes de Docker sin usar (solo con la opción avanzada)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                ForEach(m.skipped, id: \.self) { s in
                    Label(s, systemImage: "info.circle").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        } else {
            Text("Aún no se ha medido. La primera medición se hará en cuanto el Mac esté tranquilo, o puedes lanzarla ahora.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Acciones

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if confirmClean || confirmVolumes {
                VStack(alignment: .leading, spacing: 6) {
                    Text(confirmVolumes
                         ? "Esto borra también los volúmenes de Docker sin usar: datos de bases de datos de contenedores parados. No se puede deshacer."
                         : "Se borran imágenes y caché de Docker, versiones viejas y caché de Homebrew, caché de npm y pip y el DerivedData de Xcode. Los volúmenes de Docker no se tocan.")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Cancelar") { confirmClean = false; confirmVolumes = false }.controlSize(.small)
                        Button(confirmVolumes ? "Borrar también volúmenes" : "Limpiar") {
                            let v = confirmVolumes
                            confirmClean = false; confirmVolumes = false
                            cleanup.cleanNow(volumes: v)
                        }
                        .controlSize(.small).buttonStyle(.borderedProminent)
                        .tint(confirmVolumes ? Severity.critical.color : .accentColor)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill((confirmVolumes ? Severity.critical.color : Severity.warn.color).opacity(0.1)))
            } else {
                HStack(spacing: 6) {
                    Button { confirmClean = true } label: { Label("Limpiar ahora", systemImage: "sparkles") }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Button { cleanup.cleanWhenIdle(volumes: false) } label: { Label("Cuando esté tranquilo", systemImage: "moon.zzz") }
                        .controlSize(.small)
                        .disabled(cleanup.state.pendingClean != nil)
                        .help("Se ejecuta en cuanto la CPU y la memoria estén tranquilas")
                    Menu {
                        Button("Medir ahora") { cleanup.measureNow() }
                        Divider()
                        Button("Limpiar incluyendo volúmenes de Docker…") { confirmVolumes = true }
                        Button("Limpiar volúmenes cuando esté tranquilo") { cleanup.cleanWhenIdle(volumes: true) }
                        Divider()
                        Button("Ver registro de la última limpieza") { NSWorkspace.shared.open(AppPaths.cleanupLog) }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
        }
    }

    private func runningView(_ job: RunningJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(job.kind.label) \(job.trigger.label) en curso").font(.callout.weight(.medium))
                    Text(job.section).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(job.started, style: .timer).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Button("Cancelar") { cleanup.cancelRunning() }.controlSize(.small)
            }
            if job.trigger != .manual {
                Text("Corre con prioridad baja y se cancela sola si la CPU pasa del \(Prefs.int(Prefs.Key.abortCPU))%.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if job.kind != .measure {
                DisclosureGroup(isExpanded: $showLog) {
                    ScrollView {
                        Text(job.log.suffix(60).joined(separator: "\n"))
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 120)
                } label: { Text("Ver salida").font(.caption) }
            }
        }
    }

    // MARK: Programación

    @ViewBuilder
    private var schedule: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ejecuciones programadas").font(.caption.weight(.semibold)).foregroundStyle(.secondary)

            if let pending = cleanup.state.pendingClean {
                HStack {
                    Label("\(pending.label) pendiente: en cuanto el Mac esté tranquilo", systemImage: "moon.zzz.fill")
                        .font(.caption)
                    Spacer()
                    Button("Cancelar") { cleanup.cancelPendingClean() }.controlSize(.mini)
                }
            }

            if let next = cleanup.nextRunDate {
                HStack(spacing: 6) {
                    Image(systemName: cleanup.isRetrying ? "pause.circle" : "clock").foregroundStyle(cleanup.isRetrying ? Severity.warn.color : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(cleanup.isRetrying ? "Reintento a las \(Fmt.time(next))" : "\(cleanup.nextRunKind.label) a las \(Fmt.time(next))")
                            .font(.caption.weight(.medium))
                        Text(next > Date() ? Fmt.relative(next) : "en cuanto se cumplan las condiciones")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if cleanup.state.pendingClean == nil {
                        Button("Saltar") { cleanup.skipNextMeasure() }.controlSize(.mini).help("Saltar esta medición y programar la siguiente")
                    }
                    Button("Medir ahora") { cleanup.measureNow() }.controlSize(.mini).disabled(cleanup.running != nil)
                        .help("Medir ya, sin mirar la carga del Mac")
                }
            }

            Text("Solo se ejecuta si la CPU media de \(window) min está por debajo del \(idleAvg)%, la CPU actual por debajo del \(idleNow)% y la memoria en presión normal. Si no, se reprograma \(Prefs.int(Prefs.Key.retryMinutes)) min después.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Historial de ejecuciones

    @ViewBuilder
    private var runs: some View {
        let all = cleanup.state.runs
        if !all.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Historial").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(all.prefix(showAllRuns ? 60 : 5)) { r in RunRow(run: r) }
                if all.count > 5 {
                    Button(showAllRuns ? "Ver menos" : "Ver las \(all.count)") { showAllRuns.toggle() }
                        .buttonStyle(.link).font(.caption)
                }
            }
        }
    }
}

struct RunRow: View {
    var run: RunRecord

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: run.status.symbol)
                .font(.system(size: 12))
                .foregroundStyle(color)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text("\(run.kind.label) \(run.trigger.label)").font(.caption.weight(.medium))
                    Text("· \(run.status.label)").font(.caption).foregroundStyle(color)
                    if run.attempts > 1 {
                        Text("×\(run.attempts)").font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 4).background(Capsule().fill(Palette.track))
                            .help("\(run.attempts) intentos aplazados seguidos")
                    }
                    Spacer()
                    Text(Fmt.time(run.ended ?? run.started)).font(.caption2).foregroundStyle(.tertiary)
                }
                Text(run.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                if run.attempts > 1 {
                    Text("Primer intento a las \(Fmt.time(run.started))").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var color: Color {
        switch run.status {
        case .done: Severity.ok.color
        case .postponed: Severity.warn.color
        case .failed, .cancelled: Severity.critical.color
        case .running: .accentColor
        case .skipped: .secondary
        }
    }
}
