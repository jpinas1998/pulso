import AppKit
import SwiftUI

// Piezas pequeñas reutilizadas en todo el panel.

enum Palette {
    static let app = Color(red: 0.36, green: 0.55, blue: 1.0)
    static let wired = Color(red: 0.98, green: 0.62, blue: 0.20)
    static let compressed = Color(red: 0.75, green: 0.45, blue: 0.98)
    static let cached = Color(red: 0.55, green: 0.70, blue: 0.80)
    static let free = Color.primary.opacity(0.10)
    static let track = Color.primary.opacity(0.08)
    static let card = Color.primary.opacity(0.045)
}

struct Bar: View {
    var value: Double
    var color: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule().fill(color).frame(width: max(height, g.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.4), value: value)
    }
}

struct SegmentBar: View {
    var segments: [(value: Double, color: Color)]
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { g in
            let total = max(segments.map(\.value).reduce(0, +), 1)
            HStack(spacing: 1.5) {
                ForEach(segments.indices, id: \.self) { i in
                    Rectangle().fill(segments[i].color)
                        .frame(width: max(0, (g.size.width - 1.5 * CGFloat(segments.count - 1)) * segments[i].value / total))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: height / 2.5))
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.4), value: segments.map(\.value))
    }
}

struct CardBackground: ViewModifier {
    var padding: CGFloat = 10
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))
    }
}

extension View {
    func card(padding: CGFloat = 10) -> some View { modifier(CardBackground(padding: padding)) }
}

struct StatRow: View {
    var label: String
    var value: String
    var dot: Color?
    var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                Text(label).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(value).monospacedDigit().fontWeight(.medium)
            }
            if let hint {
                Text(hint).font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
    }
}

/// Etiqueta de puerto. Clic → abre http://localhost:puerto (si parece HTTP).
struct PortChip: View {
    var port: PortRef
    var tint: Color
    var small = false
    @State private var hover = false

    var body: some View {
        HStack(spacing: 2) {
            if port.exposed {
                Image(systemName: "globe").font(.system(size: small ? 7.5 : 8.5, weight: .semibold))
                    .help("Escucha en todas las interfaces: accesible desde otros equipos de la red")
            }
            Text(verbatim: port.proto == .udp ? "udp:\(port.port)" : ":\(port.port)")
                .font(.system(size: small ? 10 : 11, weight: .medium, design: .monospaced))
        }
        .padding(.horizontal, small ? 5 : 6)
        .padding(.vertical, small ? 1.5 : 2.5)
        .background(Capsule().fill(tint.opacity(hover && port.isLikelyHTTP ? 0.28 : 0.14)))
        .foregroundStyle(tint)
        .onHover { hover = $0 }
        .onTapGesture {
            guard port.isLikelyHTTP, let url = URL(string: "http://localhost:\(port.port)") else { return }
            NSWorkspace.shared.open(url)
        }
        .help(port.isLikelyHTTP ? "Abrir http://localhost:\(port.port)" : "Puerto \(port.proto.rawValue) \(port.port)")
    }
}

/// Coloca las vistas en filas que saltan de línea (para las etiquetas de puertos).
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowH = max(rowH, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}

struct IconButton: View {
    var symbol: String
    var help: String
    var color: Color = .secondary
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hover ? Color.primary : color)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(hover ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

enum ChartRange: String, CaseIterable, Identifiable {
    case live = "En vivo", day = "24 h", week = "7 días"
    var id: String { rawValue }
    var interval: TimeInterval { self == .day ? 86400 : 7 * 86400 }
}

extension ProcessInfo.ThermalState {
    var label: String? {
        switch self {
        case .nominal: nil
        case .fair: "Templado"
        case .serious: "Caliente: el Mac reduce velocidad"
        case .critical: "Muy caliente"
        @unknown default: nil
        }
    }
}
