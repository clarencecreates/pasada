import SwiftUI
import WidgetKit

struct ContentView: View {
    @Binding var placard: Placard
    @State private var sign: SignDraft
    @State private var selectedID: UUID?
    @State private var draggingFrom: [UUID: CGPoint] = [:]
    @State private var selectedResizeStart: Double?
    @State private var selectedRotationStart: Double?
    @State private var history: [SignDraft]
    @State private var historyIndex: Int
    @FocusState private var focusedLayer: UUID?

    init(placard: Binding<Placard>) {
        _placard = placard
        _sign = State(initialValue: placard.wrappedValue.sign)
        _history = State(initialValue: [placard.wrappedValue.sign])
        _historyIndex = State(initialValue: 0)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                editorBar
                canvas
                hiddenTextInput
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Pasada")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) { formattingBar }
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button(action: undo) { Image(systemName: "arrow.uturn.backward") }
                        .disabled(historyIndex == 0)
                    Button(action: redo) { Image(systemName: "arrow.uturn.forward") }
                        .disabled(historyIndex >= history.count - 1)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }.bold()
                }
            }
        }
    }

    @ViewBuilder private var formattingBar: some View {
        if let id = selectedID, let layer = sign.layers.first(where: { $0.id == id }), focusedLayer == id {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    Menu {
                        Picker("Font", selection: binding(for: id, \.font)) {
                            ForEach(SignFont.allCases) { Text($0.title).tag($0) }
                        }
                    } label: { Label(layer.font.title, systemImage: "textformat") }

                    Menu {
                        Slider(value: binding(for: id, \.size), in: 0.10...0.55)
                    } label: { Text("\(Int(layer.size * 100)) pt") }

                    Button { update(id) { $0.isBold.toggle() } } label: {
                        Image(systemName: "bold").foregroundStyle(layer.isBold ? Color.accentColor : Color.primary)
                    }
                    Button { update(id) { $0.curve = $0.curve == 0 ? 0.45 : 0 } } label: {
                        Image(systemName: "text.line.first.and.arrowtriangle.forward").foregroundStyle(layer.curve == 0 ? Color.primary : Color.accentColor)
                    }
                    Button { update(id) { $0.rotation = abs($0.rotation) < 45 ? 90 : 0 } } label: {
                        Image(systemName: "rotate.90").foregroundStyle(abs(layer.rotation) < 45 ? Color.primary : Color.accentColor)
                    }
                    ColorPicker("Color", selection: colorBinding(for: id, gradient: false), supportsOpacity: false).labelsHidden()
                    Toggle("Gradient", isOn: binding(for: id, \.usesGradient)).labelsHidden()
                    Button { focusedLayer = nil; selectedID = nil } label: { Image(systemName: "checkmark.circle.fill").font(.title3) }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 13)
            }
            .background(.ultraThinMaterial)
        }
    }

    private var editorBar: some View {
        HStack {
            Label("Tap a line to edit", systemImage: "hand.tap.fill")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button { addTextLayer() } label: { Image(systemName: "plus") }
                .buttonStyle(.bordered)
            Menu {
                Toggle("Show grid", isOn: signBinding(\.showsGrid))
                Toggle("Snap to grid", isOn: signBinding(\.snapToGrid))
            } label: {
                Image(systemName: sign.showsGrid ? "grid" : "grid.circle")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.background)
    }

    private var canvas: some View {
        GeometryReader { proxy in
            ZStack {
                SignRenderer(sign: sign, showGrid: sign.showsGrid)
                ForEach(sign.layers) { layer in
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: min(proxy.size.width * 0.92, 360), height: max(48, proxy.size.height * layer.size * 1.6))
                        .position(x: layer.x * proxy.size.width, y: layer.y * proxy.size.height)
                        .gesture(dragGesture(for: layer, in: proxy.size))
                        .onTapGesture {
                            selectedID = layer.id
                            focusedLayer = layer.id
                        }
                }
                if let selectedID, let layer = sign.layers.first(where: { $0.id == selectedID }) {
                    TransformSelection(layer: layer, canvasSize: proxy.size, resizeStart: $selectedResizeStart, rotationStart: $selectedRotationStart,
                                       onResize: { newSize in updateLive(selectedID) { $0.size = min(0.55, max(0.10, newSize)) } },
                                       onResizeEnd: recordCurrentState,
                                       onRotate: { degrees in updateLive(selectedID) { $0.rotation = degrees } },
                                       onRotateEnd: recordCurrentState)
                        .position(x: layer.x * proxy.size.width, y: layer.y * proxy.size.height)
                        .allowsHitTesting(true)
                }
            }
        }
        .aspectRatio(2, contentMode: .fit)
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
    }

    @ViewBuilder private var hiddenTextInput: some View {
        if let id = selectedID {
            TextField("", text: binding(for: id, \.text))
                .focused($focusedLayer, equals: id)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .opacity(0.01)
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
        }
    }

    private func dragGesture(for layer: TextLayer, in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let origin = draggingFrom[layer.id] ?? CGPoint(x: layer.x, y: layer.y)
                draggingFrom[layer.id] = origin
                updateLive(layer.id) {
                    let rawX = min(0.92, max(0.08, origin.x + value.translation.width / size.width))
                    let rawY = min(0.86, max(0.14, origin.y + value.translation.height / size.height))
                    $0.x = sign.snapToGrid ? Double((rawX * 10).rounded()) / 10.0 : Double(rawX)
                    $0.y = sign.snapToGrid ? Double((rawY * 6).rounded()) / 6.0 : Double(rawY)
                }
            }
            .onEnded { _ in
                draggingFrom[layer.id] = nil
                recordCurrentState()
            }
    }

    private func addTextLayer() {
        let layer = TextLayer(text: "NEW TEXT", font: .wide, size: 0.18, x: 0.5, y: 0.5, color: .lime, gradientColor: .pink)
        sign.layers.append(layer)
        recordCurrentState()
        selectedID = layer.id
    }

    private func save() {
        SignStore.save(sign)
        placard.sign = sign
        WidgetCenter.shared.reloadAllTimelines()
        focusedLayer = nil
    }

    private func update(_ id: UUID, _ change: (inout TextLayer) -> Void) {
        guard let index = sign.layers.firstIndex(where: { $0.id == id }) else { return }
        change(&sign.layers[index])
        recordCurrentState()
    }

    private func updateLive(_ id: UUID, _ change: (inout TextLayer) -> Void) {
        guard let index = sign.layers.firstIndex(where: { $0.id == id }) else { return }
        change(&sign.layers[index])
    }

    private func recordCurrentState() {
        if history[historyIndex] == sign { return }
        history = Array(history.prefix(historyIndex + 1))
        history.append(sign)
        historyIndex = history.count - 1
    }

    private func undo() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        sign = history[historyIndex]
    }

    private func redo() {
        guard historyIndex < history.count - 1 else { return }
        historyIndex += 1
        sign = history[historyIndex]
    }

    private func signBinding<Value>(_ keyPath: WritableKeyPath<SignDraft, Value>) -> Binding<Value> {
        Binding(
            get: { sign[keyPath: keyPath] },
            set: { value in
                sign[keyPath: keyPath] = value
                recordCurrentState()
            }
        )
    }

    private func binding<Value>(for id: UUID, _ keyPath: WritableKeyPath<TextLayer, Value>) -> Binding<Value> {
        Binding(
            get: { sign.layers.first(where: { $0.id == id })![keyPath: keyPath] },
            set: { newValue in update(id) { $0[keyPath: keyPath] = newValue } }
        )
    }

    private func colorBinding(for id: UUID, gradient: Bool) -> Binding<Color> {
        Binding(
            get: {
                let layer = sign.layers.first(where: { $0.id == id })!
                return (gradient ? layer.gradientColor : layer.color).color
            },
            set: { newValue in update(id) { gradient ? ($0.gradientColor = SignColor(newValue)) : ($0.color = SignColor(newValue)) } }
        )
    }
}

private struct TransformSelection: View {
    let layer: TextLayer
    let canvasSize: CGSize
    @Binding var resizeStart: Double?
    @Binding var rotationStart: Double?
    let onResize: (Double) -> Void
    let onResizeEnd: () -> Void
    let onRotate: (Double) -> Void
    let onRotateEnd: () -> Void

    private var boxWidth: CGFloat { min(canvasSize.width * 0.88, max(72, CGFloat(layer.text.count) * canvasSize.height * CGFloat(layer.size) * 0.62)) }
    private var boxHeight: CGFloat { max(52, canvasSize.height * CGFloat(layer.size) * 1.45) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .stroke(.blue, lineWidth: 1.5)
            Circle().fill(.blue).frame(width: 13, height: 13).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Circle().fill(.blue).frame(width: 13, height: 13).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            Circle().fill(.blue).frame(width: 13, height: 13).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            Circle()
                .fill(.blue)
                .frame(width: 18, height: 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .gesture(resizeGesture)
            Circle()
                .fill(.blue)
                .frame(width: 16, height: 16)
                .offset(y: -30)
                .gesture(rotationGesture)
        }
        .frame(width: boxWidth, height: boxHeight)
        .rotationEffect(.degrees(layer.rotation))
    }

    private var resizeGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                let start = resizeStart ?? layer.size
                resizeStart = start
                onResize(start + Double(value.translation.width / canvasSize.height) * 0.45)
            }
            .onEnded { _ in resizeStart = nil; onResizeEnd() }
    }

    private var rotationGesture: some Gesture {
        RotationGesture()
            .onChanged { value in
                let start = rotationStart ?? layer.rotation
                rotationStart = start
                onRotate(start + value.degrees)
            }
            .onEnded { _ in rotationStart = nil; onRotateEnd() }
    }
}
