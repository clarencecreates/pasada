import SwiftUI
import UIKit

struct SignRenderer: View {
    let sign: SignDraft
    var selectedID: UUID? = nil
    var showGrid = false
    var cornerRadius: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                background
                if showGrid {
                    PlacardGrid()
                }
                ForEach(sign.imageLayers) { layer in
                    PlacardImage(layer: layer, canvasSize: proxy.size)
                }
                ForEach(sign.layers) { layer in
                    if let rasterAsset = layer.psdRasterAsset {
                        Image(rasterAsset)
                            .resizable()
                            .scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .accessibilityHidden(true)
                    } else if let psdLayout = layer.psdLayout {
                        PSDPlacardText(
                            layer: layer,
                            layout: psdLayout,
                            canvasSize: proxy.size,
                            showsTexture: selectedID != layer.id
                        )
                        .position(
                            x: layer.x * proxy.size.width,
                            y: layer.y * proxy.size.height
                        )
                    } else {
                        PlacardText(layer: layer, canvasSize: proxy.size, showsTexture: selectedID != layer.id)
                            .position(x: layer.x * proxy.size.width, y: layer.y * proxy.size.height)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(.white.opacity(0.18), lineWidth: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Custom jeepney sign")
    }

    @ViewBuilder
    private var background: some View {
        if sign.background == .blackDriver {
            Image("BlackDriverPlacard")
                .resizable()
                .scaledToFill()
                .accessibilityHidden(true)
        } else if sign.background == .whiteBarya {
            Image("WhiteBaryaPlacard")
                .resizable()
                .scaledToFill()
                .accessibilityHidden(true)
        } else if sign.background == .yellowBayad {
            Image("YellowBayadPlacard")
                .resizable()
                .scaledToFill()
                .accessibilityHidden(true)
        } else if sign.background == .babyaLang {
            Image("BabyaLangPlacard")
                .resizable()
                .scaledToFill()
                .accessibilityHidden(true)
        } else if sign.background == .yellowArch {
            Rectangle().fill(.black)
            Image("YellowArchPlacard")
                .resizable()
                .scaledToFill()
                // The generated PNG contains transparent padding around the sign.
                // Scale it just enough that the actual placard reaches the canvas edge.
                .scaleEffect(x: 1.18, y: 1.42)
                .accessibilityHidden(true)
        } else {
            Image("BlackPlacard")
                .resizable()
                .scaledToFill()
                // The source has been cropped to the artwork. This small zoom removes
                // the remaining export edge while keeping its worn painted border.
                .scaleEffect(1.08)
                .accessibilityHidden(true)
        }
    }
}

/// Renders imported PSD type inside its recorded Photoshop bounding frame rather
/// than the resizable editor text box. The content remains a live `TextLayer`.
private struct PSDPlacardText: View {
    let layer: TextLayer
    let layout: PSDTextLayout
    let canvasSize: CGSize
    var showsTexture = true

    // Imported template type is authored in Photopea pixels on a 576px-wide
    // artboard. Convert that source value to the active SwiftUI canvas instead
    // of interpreting a Photopea value such as 92px as an iOS 92pt font.
    private var fontSize: CGFloat {
        CanvasTypography.pointSize(layer.size, canvasWidth: canvasSize.width)
    }

    private var textBoxWidth: CGFloat {
        if let width = layer.width {
            return canvasSize.width * CGFloat(width)
        }
        let uiFont = CanvasTypography.uiFont(for: layer, size: fontSize)
        return max(28, (layer.text.uppercased() as NSString).size(withAttributes: [
            .font: uiFont,
            .kern: fontSize * layer.letterSpacing
        ]).width)
    }

    private var treatment: LinearGradient {
        LinearGradient(colors: [layer.color.color, layer.gradientColor.color], startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        let lettering = Text(layer.text.uppercased())
            .font(CanvasTypography.font(for: layer, size: fontSize))
            .tracking(fontSize * layer.letterSpacing)
            .multilineTextAlignment(.center)

        lettering
            .foregroundStyle(layer.usesGradient ? AnyShapeStyle(treatment) : AnyShapeStyle(layer.color.color))
            .frame(width: textBoxWidth)
            .fixedSize(horizontal: false, vertical: true)
            .overlay {
                if showsTexture {
                    PaintedGrain()
                        .mask(
                            lettering
                                .frame(width: textBoxWidth)
                                .fixedSize(horizontal: false, vertical: true)
                        )
                }
            }
            .compositingGroup()
            .scaleEffect(x: layer.resolvedHorizontalScale, y: 1)
            .rotationEffect(.degrees(layer.rotation))
    }
}

/// An image layer. A missing file draws nothing instead of failing the whole
/// placard, which matters most in the widget.
private struct PlacardImage: View {
    let layer: ImageLayer
    let canvasSize: CGSize

    var body: some View {
        if let image = PlacardImageStore.image(for: layer.assetID) {
            let width = canvasSize.width * layer.width
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: width, height: width * layer.aspectRatio)
                .rotationEffect(.degrees(layer.rotation))
                .position(x: layer.x * canvasSize.width, y: layer.y * canvasSize.height)
                .accessibilityHidden(true)
        }
    }
}

private struct PlacardGrid: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                let columns = 10
                let rows = 6
                for column in 1..<columns {
                    let x = proxy.size.width * CGFloat(column) / CGFloat(columns)
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                }
                for row in 1..<rows {
                    let y = proxy.size.height * CGFloat(row) / CGFloat(rows)
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                }
            }
            .stroke(.white.opacity(0.16), lineWidth: 0.6)
            Path { path in
                path.move(to: CGPoint(x: proxy.size.width / 2, y: 0))
                path.addLine(to: CGPoint(x: proxy.size.width / 2, y: proxy.size.height))
                path.move(to: CGPoint(x: 0, y: proxy.size.height / 2))
                path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height / 2))
            }
            .stroke(.blue.opacity(0.65), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
        .allowsHitTesting(false)
    }
}

struct PlacardText: View {
    let layer: TextLayer
    let canvasSize: CGSize
    var showsTexture = true

    private var treatment: LinearGradient {
        LinearGradient(colors: [layer.color.color, layer.gradientColor.color], startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        let fontSize = CanvasTypography.pointSize(layer.size, canvasWidth: canvasSize.width)
        let textWidth = canvasSize.width * (layer.width ?? 0.88)
        lettering(fontSize: fontSize, textWidth: textWidth)
            .foregroundStyle(layer.usesGradient ? AnyShapeStyle(treatment) : AnyShapeStyle(layer.color.color))
            .frame(width: textWidth)
            .multilineTextAlignment(.center)
            // A deliberately light, deterministic paint treatment. It is masked by the
            // live text, so the user's color and every editable character stay intact.
            .overlay {
                if showsTexture {
                    PaintedGrain()
                        .mask(
                            lettering(fontSize: fontSize, textWidth: textWidth)
                                .frame(width: textWidth)
                                .multilineTextAlignment(.center)
                        )
                }
            }
            .compositingGroup()
            .scaleEffect(x: layer.resolvedHorizontalScale, y: 1)
            .rotationEffect(.degrees(layer.rotation))
            .lineLimit(abs(layer.curve) > 0.01 ? 1 : nil)
            .minimumScaleFactor(0.25)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func lettering(fontSize: CGFloat, textWidth: CGFloat) -> some View {
        Group {
            let glyphs = Array(layer.text.uppercased()).filter { !$0.isWhitespace }
            if let offsets = layer.glyphOffsets, offsets.count == glyphs.count {
                ZStack {
                    ForEach(glyphs.indices, id: \.self) { index in
                        let offset = offsets[index]
                        Text(String(glyphs[index]))
                            .font(CanvasTypography.font(for: layer, size: fontSize))
                            .tracking(fontSize * layer.letterSpacing)
                            .rotationEffect(.degrees(offset.rotation))
                            .position(
                                x: textWidth / 2 + CGFloat(offset.x) * fontSize,
                                y: fontSize * (0.85 + CGFloat(offset.y))
                            )
                    }
                }
                .frame(width: textWidth, height: fontSize * 1.7)
            } else if abs(layer.curve) > 0.01 {
                let arc = CurvedTextLayout(layer: layer, fontSize: fontSize)
                ZStack {
                    ForEach(arc.glyphs.indices, id: \.self) { index in
                        let glyph = arc.glyphs[index]
                        Text(glyph.character)
                            .font(CanvasTypography.font(for: layer, size: fontSize))
                            .fixedSize()
                            .rotationEffect(.radians(glyph.angle))
                            .position(
                                x: arc.size.width / 2 + glyph.center.x,
                                y: arc.size.height / 2 + glyph.center.y
                            )
                    }
                }
                .frame(width: arc.size.width, height: arc.size.height)
            } else {
                Text(layer.text.uppercased())
                    .font(CanvasTypography.font(for: layer, size: fontSize))
                    .tracking(fontSize * layer.letterSpacing)
                    .lineSpacing(fontSize * layer.lineSpacing)
            }
        }
    }
}

/// Fine printed/painted variation without an image asset. Keep the contrast low so
/// small text in a Home Screen widget remains readable.
private struct PaintedGrain: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 4
            let columns = max(1, Int(size.width / spacing))
            let rows = max(1, Int(size.height / spacing))

            for row in 0...rows {
                for column in 0...columns {
                    // Stable pseudo-random values prevent the texture from flickering
                    // while the user edits or the widget reloads.
                    let seed = (row &* 37 &+ column &* 17) % 23
                    guard seed < 8 else { continue }
                    let x = CGFloat(column) * spacing + CGFloat(seed % 3)
                    let y = CGFloat(row) * spacing + CGFloat(seed % 2)
                    let opacity = seed < 2 ? 0.20 : 0.10
                    context.fill(
                        Path(CGRect(x: x, y: y, width: seed < 2 ? 1.5 : 1, height: 1)),
                        with: .color(.black.opacity(opacity))
                    )
                }
            }
        }
        .blendMode(.multiply)
        .allowsHitTesting(false)
    }
}

/// Lays a line of text along a circular arc. Each letter is placed by its
/// distance along the arc (so spacing stays even) and turned to the arc's
/// tangent at that point. Positive curve arches up (∩), negative dips (∪);
/// ±1 bends the line into a half circle. Shared by the renderer and the
/// editor's hit-testing so the selection box matches the drawn text.
struct CurvedTextLayout {
    struct Glyph {
        let character: String
        /// Centre of the letter, relative to the centre of `size`.
        let center: CGPoint
        /// Clockwise rotation in radians.
        let angle: Double
    }

    static let maximumSweep = Double.pi

    let glyphs: [Glyph]
    let size: CGSize

    init(layer: TextLayer, fontSize: CGFloat) {
        let font = CanvasTypography.uiFont(for: layer, size: fontSize)
        let tracking = fontSize * layer.letterSpacing
        let characters = Array(layer.text.uppercased()).map(String.init)
        let advances = characters.map { ($0 as NSString).size(withAttributes: [.font: font]).width + tracking }
        let totalWidth = max(1, advances.reduce(0, +) - (characters.isEmpty ? 0 : tracking))
        let lineHeight = font.lineHeight

        let sweep = layer.curve * Self.maximumSweep
        let direction: Double = sweep >= 0 ? 1 : -1
        let radius = Double(totalWidth) / max(abs(sweep), 0.0001)

        var placed: [Glyph] = []
        var cursor: CGFloat = 0
        for (character, advance) in zip(characters, advances) {
            // Arc length from the middle of the line to the middle of this letter.
            let distance = Double(cursor + (advance - tracking) / 2 - totalWidth / 2)
            let theta = distance / radius
            placed.append(Glyph(
                character: character,
                center: CGPoint(
                    x: radius * sin(theta),
                    y: direction * radius * (1 - cos(theta))
                ),
                angle: direction * theta
            ))
            cursor += advance
        }

        // Bounds of every rotated letter box, then recentre on them.
        var minX = CGFloat.infinity, maxX = -CGFloat.infinity
        var minY = CGFloat.infinity, maxY = -CGFloat.infinity
        for (glyph, advance) in zip(placed, advances) {
            let halfW = (advance - tracking) / 2, halfH = lineHeight / 2
            let c = CGFloat(cos(glyph.angle)), s = CGFloat(sin(glyph.angle))
            let extentX = abs(halfW * c) + abs(halfH * s)
            let extentY = abs(halfW * s) + abs(halfH * c)
            minX = min(minX, glyph.center.x - extentX); maxX = max(maxX, glyph.center.x + extentX)
            minY = min(minY, glyph.center.y - extentY); maxY = max(maxY, glyph.center.y + extentY)
        }
        guard minX.isFinite else {
            glyphs = []
            size = CGSize(width: 1, height: lineHeight)
            return
        }
        let midX = (minX + maxX) / 2, midY = (minY + maxY) / 2
        glyphs = placed.map {
            Glyph(character: $0.character, center: CGPoint(x: $0.center.x - midX, y: $0.center.y - midY), angle: $0.angle)
        }
        size = CGSize(width: maxX - minX, height: maxY - minY)
    }
}
