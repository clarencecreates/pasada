import SwiftUI

struct SignRenderer: View {
    let sign: SignDraft
    var selectedID: UUID? = nil
    var showGrid = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                background
                if showGrid || sign.showsGrid {
                    PlacardGrid()
                }
                ForEach(sign.layers) { layer in
                    PlacardText(layer: layer, canvasSize: proxy.size)
                        .position(x: layer.x * proxy.size.width, y: layer.y * proxy.size.height)
                        .overlay {
                            if selectedID == layer.id {
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(.blue, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                                    .padding(-7)
                            }
                        }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.18), lineWidth: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Custom jeepney sign")
    }

    @ViewBuilder
    private var background: some View {
        if sign.background == .yellowArch {
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

    private var treatment: LinearGradient {
        LinearGradient(colors: [layer.color.color, layer.gradientColor.color], startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        let fontSize = max(12, canvasSize.height * layer.size)
        lettering(fontSize: fontSize)
            .foregroundStyle(layer.usesGradient ? AnyShapeStyle(treatment) : AnyShapeStyle(layer.color.color))
            // A deliberately light, deterministic paint treatment. It is masked by the
            // live text, so the user's color and every editable character stay intact.
            .overlay {
                PaintedGrain()
                    .mask(lettering(fontSize: fontSize))
            }
            .rotationEffect(.degrees(layer.rotation))
            .lineLimit(1)
            .minimumScaleFactor(0.25)
            .fixedSize()
    }

    @ViewBuilder
    private func lettering(fontSize: CGFloat) -> some View {
        Group {
            if abs(layer.curve) > 0.01 {
                HStack(spacing: -fontSize * 0.05) {
                    ForEach(Array(layer.text.uppercased()).indices, id: \.self) { index in
                        let count = max(1, layer.text.count - 1)
                        let progress = Double(index) / Double(count)
                        let arc = sin(progress * .pi) * layer.curve
                        Text(String(Array(layer.text.uppercased())[index]))
                            .font(.custom(layer.font.postScriptName, size: fontSize))
                            .fontWeight(layer.isBold ? .black : .regular)
                            .rotationEffect(.degrees((progress - 0.5) * layer.curve * -25))
                            .offset(y: -arc * fontSize * 0.45)
                    }
                }
            } else {
                Text(layer.text.uppercased())
                    .font(.custom(layer.font.postScriptName, size: fontSize))
                    .fontWeight(layer.isBold ? .black : .regular)
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
