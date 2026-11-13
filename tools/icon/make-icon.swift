// Genera el icono de la app (1024 px) y el catálogo AppIcon con todos los tamaños.
// Uso: swift tools/icon/make-icon.swift
import AppKit
import SwiftUI

struct IconView: View {
    let green = Color(red: 0.25, green: 0.85, blue: 0.55)
    let amber = Color(red: 1.0, green: 0.72, blue: 0.20)
    let red = Color(red: 1.0, green: 0.36, blue: 0.33)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 186, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.13, green: 0.15, blue: 0.26), Color(red: 0.07, green: 0.08, blue: 0.15)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 186, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 4))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 12)

            Group {
                Circle().trim(from: 0.125, to: 0.875)
                    .stroke(Color.white.opacity(0.10), style: StrokeStyle(lineWidth: 64, lineCap: .round))
                Circle().trim(from: 0.125, to: 0.875)
                    .stroke(AngularGradient(colors: [green, green, amber, red], center: .center,
                                            startAngle: .degrees(45), endAngle: .degrees(315)),
                            style: StrokeStyle(lineWidth: 64, lineCap: .round))
            }
            .frame(width: 500, height: 500)
            .rotationEffect(.degrees(90))
            .offset(y: 30)

            Capsule()
                .fill(Color.white)
                .frame(width: 34, height: 230)
                .offset(y: -115)
                .rotationEffect(.degrees(38))
                .offset(y: 30)
                .shadow(color: .black.opacity(0.3), radius: 8)
            Circle().fill(Color.white).frame(width: 96, height: 96).offset(y: 30)
            Circle().fill(Color(red: 0.13, green: 0.15, blue: 0.26)).frame(width: 36, height: 36).offset(y: 30)
        }
        .frame(width: 1024, height: 1024)
    }
}

let dir = URL(fileURLWithPath: "Pulso/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

@MainActor func make() {
    let r = ImageRenderer(content: IconView())
    r.scale = 1
    guard let cg = r.cgImage else { fatalError("no se pudo renderizar") }
    let master = NSBitmapImageRep(cgImage: cg)
    let sizes: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
    var images: [[String: String]] = []
    for (pt, scale) in sizes {
        let px = pt * scale
        let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        master.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
    }
    let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
    try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
        .write(to: dir.appendingPathComponent("Contents.json"))
    try! master.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "tools/icon/icono-1024.png"))
    print("✓ Icono generado")
}
MainActor.assumeIsolated { make() }
