import SwiftUI

/// First-launch walkthrough: four looping, watch-only demos of the real
/// gestures, then the user picks their first placard so the library never
/// opens empty. Shown once.
struct OnboardingView: View {
    let finish: (SignDraft) -> Void

    @State private var page = 0
    @State private var chosen: PlaceholderTemplate?
    private let lastPage = 4

    var body: some View {
        ZStack {
            Color.widyipBackground.ignoresSafeArea()
            AmbientLight().ignoresSafeArea()

            VStack(spacing: 0) {
                header

                TabView(selection: $page) {
                    OnboardingPage(
                        title: "Your sign, on your\nHome Screen",
                        subtitle: "Make a jeepney placard and hang it as a widget.",
                        isActive: page == 0
                    ) { WelcomeDemo(isActive: page == 0) }
                    .tag(0)

                    OnboardingPage(
                        title: "Swipe to browse",
                        subtitle: "All your placards live in one deck.",
                        isActive: page == 1
                    ) { BrowseDemo(isActive: page == 1) }
                    .tag(1)

                    OnboardingPage(
                        title: "Drag down to equip",
                        subtitle: "Drop a placard into the slot and your widget updates. Drag up to remove one, and undo if you change your mind.",
                        isActive: page == 2
                    ) { EquipDemo(isActive: page == 2) }
                    .tag(2)

                    OnboardingPage(
                        title: "Make it yours",
                        subtitle: "Edit every line, add photos, and bend text into curves.",
                        isActive: page == 3
                    ) { EditDemo(isActive: page == 3) }
                    .tag(3)

                    PickPage(isActive: page == lastPage, chosen: $chosen)
                        .tag(lastPage)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                footer
            }
        }
        .environment(\.colorScheme, .dark)
        .sensoryFeedback(.selection, trigger: page)
        .sensoryFeedback(.selection, trigger: chosen)
    }

    private var header: some View {
        HStack {
            ProgressIndicator(count: lastPage + 1, index: page)
            Spacer()
            Button("Skip") {
                withAnimation(.smooth(duration: 0.5)) { page = lastPage }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.7))
            .opacity(page < lastPage ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: page)
        }
        .padding(.horizontal, 24)
        .frame(height: 44)
    }

    private var footer: some View {
        let isLast = page == lastPage
        let isEnabled = !isLast || chosen != nil

        return Button {
            if isLast {
                if let chosen { finish(chosen.liveSign) }
            } else {
                withAnimation(.smooth(duration: 0.5)) { page += 1 }
            }
        } label: {
            Text(isLast ? "Start with this placard" : "Continue")
                .font(.headline)
                .foregroundStyle(isEnabled ? .black : .white.opacity(0.4))
                .contentTransition(.opacity)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(isEnabled ? Color.white : .white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!isEnabled)
        .animation(.smooth(duration: 0.3), value: isEnabled)
        .animation(.smooth(duration: 0.3), value: isLast)
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }
}

// MARK: - Shared pieces

extension PlaceholderTemplate {
    /// The template as live, editable text, exactly as the editor shows it.
    var liveSign: SignDraft {
        makeSign().applyingImportedPSDLayout().bakingImportedPSDType()
    }
}

private enum Samples {
    static let signs = PlaceholderTemplate.allCases.map(\.liveSign)
}

/// A title and subtitle that rise in from a soft blur, under a demo stage.
private struct OnboardingPage<Demo: View>: View {
    let title: String
    let subtitle: String
    let isActive: Bool
    @ViewBuilder let demo: Demo

    var body: some View {
        VStack(spacing: 0) {
            demo
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 32, weight: .bold))
                    .multilineTextAlignment(.center)
                    .reveal(isActive, delay: 0.1)
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .reveal(isActive, delay: 0.2)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 28)
        }
    }
}

private struct Reveal: ViewModifier {
    let isActive: Bool
    let delay: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .blur(radius: shown ? 0 : 12)
            .offset(y: shown ? 0 : 16)
            .onChange(of: isActive, initial: true) { _, active in
                if active {
                    withAnimation(.smooth(duration: 0.8).delay(delay)) { shown = true }
                } else {
                    shown = false
                }
            }
    }
}

private extension View {
    func reveal(_ isActive: Bool, delay: Double = 0) -> some View {
        modifier(Reveal(isActive: isActive, delay: delay))
    }
}

private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

private struct ProgressIndicator: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { dot in
                Capsule()
                    .fill(dot == index ? AnyShapeStyle(.widyip) : AnyShapeStyle(.white.opacity(0.22)))
                    .frame(width: dot == index ? 22 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: index)
        .accessibilityElement()
        .accessibilityLabel("Step \(index + 1) of \(count)")
    }
}

/// Two slow, heavily blurred pools of the logo's lime and pink.
private struct AmbientLight: View {
    @State private var drift = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Circle()
                    .fill(Color.widyipLime)
                    .frame(width: proxy.size.width * 0.9)
                    .offset(x: drift ? -proxy.size.width * 0.25 : -proxy.size.width * 0.05,
                            y: drift ? -proxy.size.height * 0.28 : -proxy.size.height * 0.18)
                Circle()
                    .fill(Color.widyipPink)
                    .frame(width: proxy.size.width * 0.9)
                    .offset(x: drift ? proxy.size.width * 0.2 : proxy.size.width * 0.3,
                            y: drift ? proxy.size.height * 0.05 : -proxy.size.height * 0.08)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .blur(radius: 120)
            .opacity(0.16)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { drift = true }
        }
    }
}

/// The demo finger: a soft translucent disc that dips when it presses.
struct GhostFinger: View {
    var pressed = false

    var body: some View {
        Circle()
            .fill(.white.opacity(0.85))
            .frame(width: 42, height: 42)
            .overlay { Circle().stroke(.white.opacity(0.35), lineWidth: 8).blur(radius: 4) }
            .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
            .scaleEffect(pressed ? 0.82 : 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct FingerState {
    var position: CGPoint = .zero
    var visible = false
    var pressed = false
}

/// Sleeps, returning false once the demo is no longer on screen.
private func pause(_ seconds: Double) async -> Bool {
    do {
        try await Task.sleep(for: .seconds(seconds))
        return true
    } catch {
        return false
    }
}

private struct DemoCard: View {
    let sign: SignDraft

    var body: some View {
        SignRenderer(sign: sign, cornerRadius: 14)
            .shadow(color: .black.opacity(0.5), radius: 16, y: 10)
    }
}

// MARK: - 1. Welcome

/// The placard drops onto its suction cups and settles with a damped swing,
/// then follows the phone's tilt.
private struct WelcomeDemo: View {
    let isActive: Bool
    @StateObject private var tilt = DeviceTiltObserver()
    @State private var start = Date()

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(paused: !isActive)) { timeline in
                let t = max(0, timeline.date.timeIntervalSince(start))
                let fall = min(1, t / 0.55)
                let eased = 1 - pow(1 - fall, 3)
                let swingTime = max(0, t - 0.45)
                let swing = 11 * exp(-1.15 * swingTime) * sin(4.4 * swingTime)

                HangingPlacard(
                    placard: Placard(sign: Samples.signs[1]),
                    roll: swing + tilt.x * 4,
                    yaw: tilt.x * 6
                )
                .frame(width: min(proxy.size.width - 48, 340))
                .shadow(color: .black.opacity(0.5), radius: 24, y: 18)
                .opacity(fall)
                .position(x: proxy.size.width / 2, y: proxy.size.height * 0.5 - (1 - eased) * 220)
            }
        }
        .onChange(of: isActive, initial: true) { _, active in
            if active {
                start = .now
                tilt.start()
            } else {
                tilt.stop()
            }
        }
    }
}

// MARK: - 2. Browse

private struct BrowseDemo: View {
    let isActive: Bool
    @State private var position: CGFloat = 0
    @State private var finger = FingerState()

    var body: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width - 120, 270)
            let spacing = width * 0.86
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)

            ZStack {
                ForEach(0..<Samples.signs.count, id: \.self) { index in
                    let d = CGFloat(index) - position
                    let ad = abs(d)
                    DemoCard(sign: Samples.signs[index])
                        .frame(width: width, height: width / 2)
                        .scaleEffect(1 - min(ad, 2) * 0.15)
                        .rotation3DEffect(.degrees(Double(min(55, max(-55, -d * 34)))), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
                        .opacity(max(0, 1 - max(0, ad - 0.9) * 0.85))
                        .zIndex(10 - Double(ad))
                        .position(x: center.x + d * spacing, y: center.y)
                }

                GhostFinger(pressed: finger.pressed)
                    .opacity(finger.visible ? 1 : 0)
                    .position(x: center.x + finger.position.x, y: center.y + finger.position.y)
                    .zIndex(20)
            }
        }
        .task(id: isActive) {
            guard isActive else {
                position = 0
                finger = FingerState()
                return
            }
            await loop()
        }
    }

    private func loop() async {
        let stops: [CGFloat] = [1, 2, 1, 0]
        while true {
            for stop in stops {
                let forward = stop > position
                finger = FingerState(position: CGPoint(x: forward ? 80 : -80, y: 14))
                withAnimation(.easeOut(duration: 0.25)) { finger.visible = true }
                guard await pause(0.35) else { return }
                withAnimation(.easeOut(duration: 0.12)) { finger.pressed = true }
                guard await pause(0.15) else { return }
                withAnimation(.spring(response: 0.6, dampingFraction: 0.86)) {
                    position = stop
                    finger.position.x = forward ? -80 : 80
                }
                guard await pause(0.45) else { return }
                withAnimation(.easeIn(duration: 0.2)) {
                    finger.pressed = false
                    finger.visible = false
                }
                guard await pause(0.85) else { return }
            }
        }
    }
}

// MARK: - 3. Equip

private struct EquipDemo: View {
    let isActive: Bool
    @State private var drop: CGFloat = 0
    @State private var slotGlow: CGFloat = 0
    @State private var widgetShown = false
    @State private var finger = FingerState()

    var body: some View {
        GeometryReader { proxy in
            let cardWidth = min(proxy.size.width * 0.5, 190)
            let cardHeight = cardWidth / 2
            let leftX = proxy.size.width * 0.32
            let cardY = proxy.size.height * 0.34
            let slotY = cardY + cardHeight / 2 + 74
            let travel = slotY - cardY + cardHeight * 0.6
            // Card height still above the slot lip, in the card's own frame.
            let visible = (slotY - 6) - (cardY + drop * travel) + cardHeight / 2

            ZStack {
                DemoCard(sign: Samples.signs[0])
                    .frame(width: cardWidth, height: cardHeight)
                    .scaleEffect(1 - drop * 0.14)
                    .rotation3DEffect(.degrees(Double(drop) * 22), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.55)
                    .mask(alignment: .top) {
                        Rectangle()
                            .frame(width: cardWidth * 2, height: max(0, visible) + 300)
                            .offset(y: -300)
                    }
                    .position(x: leftX, y: cardY + drop * travel)

                slot(width: cardWidth * 0.9)
                    .position(x: leftX, y: slotY)

                MiniPhone(sign: Samples.signs[0], widgetShown: widgetShown)
                    .frame(width: 112, height: 228)
                    .position(x: proxy.size.width * 0.78, y: proxy.size.height * 0.48)

                GhostFinger(pressed: finger.pressed)
                    .opacity(finger.visible ? 1 : 0)
                    .position(x: leftX + finger.position.x, y: cardY + finger.position.y)
            }
        }
        .task(id: isActive) {
            guard isActive else {
                drop = 0
                slotGlow = 0
                widgetShown = false
                finger = FingerState()
                return
            }
            await loop()
        }
    }

    private func slot(width: CGFloat) -> some View {
        ZStack {
            Ellipse()
                .fill(.widyip)
                .frame(width: width, height: 40)
                .blur(radius: 22)
                .opacity(0.18 + 0.6 * slotGlow)
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.02), Color(white: 0.13)], startPoint: .top, endPoint: .bottom))
                .frame(width: width, height: 14)
                .overlay(alignment: .top) {
                    Capsule()
                        .fill(LinearGradient(colors: [.clear, .widyipLime, .widyipPink, .clear], startPoint: .leading, endPoint: .trailing))
                        .frame(height: 2)
                        .opacity(0.6 + 0.4 * slotGlow)
                }
        }
    }

    private func loop() async {
        while true {
            finger = FingerState(position: CGPoint(x: 10, y: 0))
            withAnimation(.easeOut(duration: 0.25)) { finger.visible = true }
            guard await pause(0.4) else { return }
            withAnimation(.easeOut(duration: 0.12)) { finger.pressed = true }
            guard await pause(0.2) else { return }

            // Pull the card down and let the slot swallow it.
            withAnimation(.easeInOut(duration: 0.75)) {
                drop = 0.62
                finger.position.y = 120
                slotGlow = 0.6
            }
            guard await pause(0.75) else { return }
            withAnimation(.easeIn(duration: 0.25)) {
                drop = 1
                finger.pressed = false
                finger.visible = false
            }
            guard await pause(0.2) else { return }
            withAnimation(.easeOut(duration: 0.15)) { slotGlow = 1 }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.72).delay(0.1)) { widgetShown = true }
            guard await pause(0.3) else { return }
            withAnimation(.easeOut(duration: 0.8)) { slotGlow = 0 }
            guard await pause(1.2) else { return }

            // The card rises back out, ready for the next loop.
            withAnimation(.spring(response: 0.65, dampingFraction: 0.78)) { drop = 0 }
            guard await pause(1.4) else { return }
            withAnimation(.smooth(duration: 0.5)) { widgetShown = false }
            guard await pause(0.7) else { return }
        }
    }
}

/// A small iPhone Home Screen whose widget flips over to the equipped placard.
private struct MiniPhone: View {
    let sign: SignDraft
    let widgetShown: Bool

    var body: some View {
        GeometryReader { proxy in
            let inset: CGFloat = 9
            let widgetWidth = proxy.size.width - inset * 2
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.07)], startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 1.5)

                VStack(spacing: 10) {
                    Capsule()
                        .fill(.black)
                        .frame(width: 34, height: 9)
                        .padding(.top, 7)

                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.white.opacity(0.1))
                            .opacity(widgetShown ? 0 : 1)
                        SignRenderer(sign: sign, cornerRadius: 10)
                            .opacity(widgetShown ? 1 : 0)
                    }
                    .frame(width: widgetWidth, height: widgetWidth / 2)
                    .rotation3DEffect(.degrees(widgetShown ? 0 : 180), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                    .shadow(color: .widyipPink.opacity(widgetShown ? 0.35 : 0), radius: 10)

                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(20), spacing: 7), count: 4), spacing: 9) {
                        ForEach(0..<12, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(.white.opacity(0.1))
                                .frame(width: 20, height: 20)
                        }
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 4. Edit

private struct EditDemo: View {
    let isActive: Bool
    @State private var selected = false
    @State private var typing = false
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var caption = "Tap a line to select it"
    @State private var finger = FingerState()

    private let sign = Samples.signs[0]
    private let lineIndex = 1

    var body: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width - 48, 340)
            let canvas = CGSize(width: width, height: width / 2)
            let origin = CGPoint(x: (proxy.size.width - width) / 2, y: proxy.size.height * 0.42 - canvas.height / 2)
            let line = sign.layers[lineIndex]
            let lineCenter = CGPoint(
                x: origin.x + line.x * canvas.width + offset.width,
                y: origin.y + line.y * canvas.height + offset.height
            )
            let textSize = EditorTextGeometry.textSize(for: line, canvasSize: canvas)
            let box = CGSize(width: textSize.width * scale + 10, height: textSize.height * scale + 10)

            ZStack(alignment: .topLeading) {
                // The placard without the demo line, which is drawn on its own so
                // it can scale and move smoothly.
                SignRenderer(sign: signWithoutLine, cornerRadius: 14)
                    .frame(width: canvas.width, height: canvas.height)
                    .shadow(color: .black.opacity(0.5), radius: 16, y: 10)
                    .offset(x: origin.x, y: origin.y)

                PlacardText(layer: line, canvasSize: canvas)
                    .scaleEffect(scale)
                    .position(lineCenter)

                selectionBox(size: box)
                    .position(lineCenter)
                    .opacity(selected ? 1 : 0)
                    .scaleEffect(selected ? 1 : 1.06)

                Capsule()
                    .fill(Color.white)
                    .frame(width: 2.5, height: textSize.height * scale * 0.7)
                    .position(x: lineCenter.x + textSize.width * scale / 2 + 4, y: lineCenter.y)
                    .opacity(typing ? 1 : 0)
                    .phaseAnimator([1.0, 0.0]) { caret, phase in
                        caret.opacity(typing ? phase : 0)
                    } animation: { _ in .easeInOut(duration: 0.5) }

                Text(caption)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(.white.opacity(0.08), in: Capsule())
                    .overlay { Capsule().stroke(.white.opacity(0.1), lineWidth: 0.5) }
                    .contentTransition(.opacity)
                    .id(caption)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                    .position(x: proxy.size.width / 2, y: origin.y + canvas.height + 54)

                GhostFinger(pressed: finger.pressed)
                    .opacity(finger.visible ? 1 : 0)
                    .position(x: lineCenter.x + finger.position.x, y: lineCenter.y + finger.position.y)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .task(id: isActive) {
                guard isActive else {
                    reset()
                    return
                }
                await loop(box: box)
            }
        }
    }

    private var signWithoutLine: SignDraft {
        var copy = sign
        copy.layers.remove(at: lineIndex)
        return copy
    }

    private func selectionBox(size: CGSize) -> some View {
        let pink = Color(red: 1, green: 0.4, blue: 0.77)
        return ZStack {
            Rectangle().stroke(pink, lineWidth: 1.2)
            ForEach(0..<4, id: \.self) { corner in
                Circle()
                    .fill(.white)
                    .frame(width: 10, height: 10)
                    .shadow(color: .black.opacity(0.3), radius: 2)
                    .position(
                        x: corner % 2 == 0 ? 0 : size.width,
                        y: corner < 2 ? 0 : size.height
                    )
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func reset() {
        selected = false
        typing = false
        scale = 1
        offset = .zero
        caption = "Tap a line to select it"
        finger = FingerState()
    }

    private func setCaption(_ text: String) {
        withAnimation(.smooth(duration: 0.35)) { caption = text }
    }

    private func tap() async -> Bool {
        withAnimation(.easeOut(duration: 0.1)) { finger.pressed = true }
        guard await pause(0.14) else { return false }
        withAnimation(.easeOut(duration: 0.14)) { finger.pressed = false }
        return true
    }

    private func loop(box: CGSize) async {
        while true {
            // Tap to select.
            setCaption("Tap a line to select it")
            finger = FingerState(position: CGPoint(x: -20, y: 30))
            withAnimation(.easeOut(duration: 0.3)) {
                finger.visible = true
                finger.position = CGPoint(x: -20, y: 4)
            }
            guard await pause(0.5), await tap() else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { selected = true }
            guard await pause(0.7) else { return }

            // Drag a corner.
            setCaption("Drag a corner to resize")
            withAnimation(.smooth(duration: 0.5)) {
                finger.position = CGPoint(x: box.width / 2, y: box.height / 2)
            }
            guard await pause(0.55) else { return }
            withAnimation(.easeOut(duration: 0.1)) { finger.pressed = true }
            guard await pause(0.15) else { return }
            withAnimation(.smooth(duration: 0.8)) {
                scale = 1.12
                finger.position = CGPoint(x: box.width / 2 * 1.12, y: box.height / 2 * 1.12)
            }
            guard await pause(0.85) else { return }
            withAnimation(.easeOut(duration: 0.14)) { finger.pressed = false }
            guard await pause(0.5) else { return }

            // Drag to move.
            setCaption("Drag to move it anywhere")
            withAnimation(.smooth(duration: 0.45)) { finger.position = CGPoint(x: 10, y: 4) }
            guard await pause(0.5) else { return }
            withAnimation(.easeOut(duration: 0.1)) { finger.pressed = true }
            guard await pause(0.15) else { return }
            withAnimation(.smooth(duration: 0.8)) { offset = CGSize(width: 0, height: 14) }
            guard await pause(0.85) else { return }
            withAnimation(.easeOut(duration: 0.14)) { finger.pressed = false }
            guard await pause(0.45) else { return }

            // Tap again to type.
            setCaption("Tap again to type")
            guard await tap() else { return }
            withAnimation(.easeOut(duration: 0.2)) { typing = true }
            guard await pause(0.3) else { return }
            withAnimation(.easeIn(duration: 0.25)) { finger.visible = false }
            guard await pause(1.6) else { return }

            // Settle back for the next loop.
            withAnimation(.smooth(duration: 0.7)) {
                typing = false
                selected = false
                scale = 1
                offset = .zero
            }
            guard await pause(1.1) else { return }
        }
    }
}

// MARK: - 5. Pick

private struct PickPage: View {
    let isActive: Bool
    @Binding var chosen: PlaceholderTemplate?

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Text("Pick your first placard")
                    .font(.system(size: 32, weight: .bold))
                    .multilineTextAlignment(.center)
                    .reveal(isActive, delay: 0.05)
                Text("You can change every word later.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.6))
                    .reveal(isActive, delay: 0.12)
            }
            .padding(.top, 16)
            .padding(.horizontal, 32)

            Spacer(minLength: 12)

            VStack(spacing: 16) {
                ForEach(Array(PlaceholderTemplate.allCases.enumerated()), id: \.element) { index, template in
                    let isChosen = chosen == template
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { chosen = template }
                    } label: {
                        SignRenderer(sign: Samples.signs[index], cornerRadius: 16)
                            .aspectRatio(2, contentMode: .fit)
                            .overlay {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(.widyip, lineWidth: 3)
                                    .opacity(isChosen ? 1 : 0)
                            }
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .heavy))
                                    .foregroundStyle(.black)
                                    .frame(width: 28, height: 28)
                                    .background(.widyip, in: Circle())
                                    .padding(10)
                                    .scaleEffect(isChosen ? 1 : 0.4)
                                    .opacity(isChosen ? 1 : 0)
                            }
                            .shadow(color: isChosen ? .widyipPink.opacity(0.35) : .black.opacity(0.4), radius: isChosen ? 18 : 10, y: 8)
                            .scaleEffect(isChosen ? 1.02 : 1)
                            .opacity(chosen == nil || isChosen ? 1 : 0.45)
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityLabel(template.title)
                    .accessibilityAddTraits(isChosen ? .isSelected : [])
                    .reveal(isActive, delay: 0.2 + Double(index) * 0.08)
                }
            }
            .frame(maxWidth: 340)
            .padding(.horizontal, 28)

            Spacer(minLength: 12)
        }
    }
}
