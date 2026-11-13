import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AlertSettings().tabItem { Label("Alertas", systemImage: "bell.badge") }
            CleanupSettings().tabItem { Label("Limpieza", systemImage: "sparkles") }
            ProfilesSettings().tabItem { Label("Perfiles", systemImage: "play.square.stack") }
        }
        .frame(width: 500)
        .padding(.vertical, 8)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject private var m: Monitor
    @AppStorage(Prefs.Key.menuBarText) private var menuBarText = "none"
    @AppStorage(Prefs.Key.liveInterval) private var liveInterval = 2.0
    @AppStorage(Prefs.Key.backgroundMinutes) private var backgroundMinutes = 5
    @AppStorage(Prefs.Key.showUDP) private var showUDP = false
    @AppStorage(Prefs.Key.hotKey) private var hotKey = "opt-cmd-p"
    @AppStorage(Prefs.Key.idleProjectMinutes) private var idleMinutes = 60
    @AppStorage(Prefs.Key.healthChecks) private var healthChecks = true
    @State private var hotKeyFailed = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Abrir Pulso al iniciar sesión", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Picker("Atajo para abrir Pulso", selection: $hotKey) {
                    ForEach(HotKey.presets) { Text($0.label).tag($0.id) }
                    Text("Desactivado").tag("none")
                }
                .onChange(of: hotKey) { _, v in hotKeyFailed = !HotKey.shared.apply(presetId: v) }
                if hotKeyFailed {
                    Text("Ese atajo ya lo usa otra app. Elige otro.").font(.caption).foregroundStyle(.red)
                }
                Picker("En la barra de menús", selection: $menuBarText) {
                    Text("Solo el icono").tag("none")
                    Text("CPU %").tag("cpu")
                    Text("Memoria %").tag("mem")
                    Text("Disco libre").tag("disk")
                }
            }
            Section {
                Stepper("Panel abierto: refrescar cada \(Int(liveInterval)) s", value: $liveInterval, in: 1...10, step: 1)
                    .onChange(of: liveInterval) { _, _ in m.scheduleLiveTimer() }
                Stepper("Panel cerrado: lectura completa cada \(backgroundMinutes) min", value: $backgroundMinutes, in: 1...30)
                Toggle("Mostrar puertos UDP", isOn: $showUDP)
                Toggle("Comprobar si los servidores responden (HTTP, una vez por minuto con el panel abierto)", isOn: $healthChecks)
                Stepper("Proyecto «sin usar» tras \(Fmt.duration(TimeInterval(idleMinutes * 60))) sin CPU", value: $idleMinutes, in: 15...480, step: 15)
            } header: {
                Text("Refresco")
            } footer: {
                Text("Con el panel cerrado solo se hace una lectura ligera por minuto (para calcular la media de CPU) y una completa cada \(backgroundMinutes) min, que también actualiza el widget.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Datos") {
                HStack {
                    Text("Historial, ejecuciones y registros")
                    Spacer()
                    Button("Abrir carpeta") { NSWorkspace.shared.open(AppPaths.support) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AlertSettings: View {
    @AppStorage(Prefs.Key.alertDisk) private var disk = true
    @AppStorage(Prefs.Key.alertDiskGB) private var diskGB = 15
    @AppStorage(Prefs.Key.alertPressure) private var pressure = true
    @AppStorage(Prefs.Key.alertSwap) private var swap = true
    @AppStorage(Prefs.Key.alertSwapGB) private var swapGB = 6
    @AppStorage(Prefs.Key.alertCPU) private var cpu = true
    @AppStorage(Prefs.Key.alertCPUPercent) private var cpuPct = 90
    @AppStorage(Prefs.Key.alertCPUMinutes) private var cpuMin = 5
    @AppStorage(Prefs.Key.alertServerDown) private var down = true
    @AppStorage(Prefs.Key.alertNewPort) private var newPort = false
    @AppStorage(Prefs.Key.alertIdleProjects) private var idleProjects = true
    @AppStorage(Prefs.Key.alertCleanup) private var cleanup = true

    var body: some View {
        Form {
            Section("Recursos") {
                Toggle("Disco con menos de \(diskGB) GB libres", isOn: $disk)
                if disk { Stepper("Umbral: \(diskGB) GB", value: $diskGB, in: 5...200, step: 5) }
                Toggle("Presión de memoria crítica", isOn: $pressure)
                Toggle("Swap por encima de \(swapGB) GB", isOn: $swap)
                if swap { Stepper("Umbral: \(swapGB) GB", value: $swapGB, in: 1...64) }
                Toggle("CPU por encima del \(cpuPct)% durante \(cpuMin) min", isOn: $cpu)
                if cpu {
                    Stepper("Umbral: \(cpuPct)%", value: $cpuPct, in: 50...100, step: 5)
                    Stepper("Durante: \(cpuMin) min", value: $cpuMin, in: 1...30)
                }
            }
            Section("Servidores") {
                Toggle("Un servidor se detiene (sin que lo cierres tú)", isOn: $down)
                Toggle("Se abre un puerto nuevo", isOn: $newPort)
                Toggle("Proyectos sin usar que ocupan más de 1 GB de RAM", isOn: $idleProjects)
            }
            Section("Limpieza") {
                Toggle("Limpieza terminada, errores y mediciones atascadas más de 24 h", isOn: $cleanup)
            }
        }
        .formStyle(.grouped)
    }
}

private struct CleanupSettings: View {
    @AppStorage(Prefs.Key.autoMeasure) private var auto = true
    @AppStorage(Prefs.Key.measureEveryHours) private var every = 6
    @AppStorage(Prefs.Key.idleWindowMinutes) private var window = 10
    @AppStorage(Prefs.Key.idleAvgCPU) private var avg = 30
    @AppStorage(Prefs.Key.idleNowCPU) private var now = 40
    @AppStorage(Prefs.Key.retryMinutes) private var retry = 10
    @AppStorage(Prefs.Key.abortCPU) private var abort = 80

    var body: some View {
        Form {
            Section {
                Toggle("Medir automáticamente el espacio liberable", isOn: $auto)
                Stepper("Cada \(every) h", value: $every, in: 1...48).disabled(!auto)
            } footer: {
                Text("Medir no borra nada: solo calcula cuánto liberaría el script.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Stepper("Ventana de reposo: \(window) min", value: $window, in: 3...60)
                Stepper("CPU media en la ventana por debajo del \(avg)%", value: $avg, in: 5...80, step: 5)
                Stepper("CPU actual por debajo del \(now)%", value: $now, in: 5...90, step: 5)
                Stepper("Si no se cumple, reintentar a los \(retry) min", value: $retry, in: 1...120)
                Stepper("Cancelar si la CPU sube del \(abort)% durante la ejecución", value: $abort, in: 40...100, step: 5)
            } header: {
                Text("Condiciones para ejecutar")
            } footer: {
                Text("Además, la presión de memoria tiene que estar en «Normal» y el swap no puede haber crecido en la ventana. Se aplica a las mediciones automáticas y a «Limpiar cuando esté tranquilo».")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Script") {
                HStack {
                    Text("limpiar-mac.sh").font(.system(.body, design: .monospaced))
                    Spacer()
                    Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: AppPaths.script)]) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProfilesSettings: View {
    @EnvironmentObject private var m: Monitor
    @EnvironmentObject private var store: ProfileStore
    @State private var newCommand: [UUID: String] = [:]

    var body: some View {
        Form {
            if store.profiles.isEmpty {
                Section {
                    Text("Aún no tienes perfiles. Con un proyecto en marcha, abre su menú ⋯ en Pulso y elige «Guardar como perfil de arranque»: se guardan los comandos tal y como están corriendo.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            ForEach($store.profiles) { $p in
                Section {
                    TextField("Nombre", text: $p.name)
                    Text(p.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.caption).foregroundStyle(.secondary)
                    ForEach(p.steps) { step in
                        HStack(alignment: .top) {
                            Image(systemName: icon(step.kind)).foregroundStyle(.secondary).frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(step.title).font(.callout)
                                Text(step.summary).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                            }
                            Spacer()
                            Button { p.steps.removeAll { $0.id == step.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        TextField("Añadir comando (p. ej. npm run dev)", text: Binding(get: { newCommand[p.id] ?? "" }, set: { newCommand[p.id] = $0 }))
                            .onSubmit { addCommand(&p) }
                        Button("Añadir") { addCommand(&p) }.disabled((newCommand[p.id] ?? "").isEmpty)
                    }
                    HStack {
                        Menu("Añadir servicio de Homebrew") {
                            ForEach(m.brewServices) { s in
                                Button(s.name) { p.steps.insert(LaunchStep(kind: .brewService, title: s.name, service: s.name), at: 0) }
                            }
                        }
                        .fixedSize()
                        Button("Añadir docker compose up") { p.steps.insert(LaunchStep(kind: .composeUp, title: "Docker Compose", cwd: p.path), at: 0) }
                        Spacer()
                        Button("Arrancar") { m.start(p) }
                        Button(role: .destructive) { store.profiles.removeAll { $0.id == p.id } } label: { Text("Borrar perfil") }
                    }
                } header: {
                    Text(p.name)
                }
            }
            Section {
                Text("Los comandos se lanzan en segundo plano en su carpeta, con las variables de entorno que tenían al guardarlos (sin secretos: esos se cargan de tu .env). La salida queda en ~/Library/Logs/Pulso.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Abrir carpeta de logs") { NSWorkspace.shared.open(Launch.logsDir) }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 380)
    }

    private func icon(_ k: LaunchStep.Kind) -> String {
        switch k {
        case .command: "terminal"
        case .brewService: "cylinder.split.1x2"
        case .composeUp: "shippingbox"
        }
    }

    private func addCommand(_ p: inout LaunchProfile) {
        let cmd = (newCommand[p.id] ?? "").trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else { return }
        p.steps.append(LaunchStep(kind: .command, title: cmd, cwd: p.path, args: ["/bin/zsh", "-lc", cmd]))
        newCommand[p.id] = ""
    }
}
