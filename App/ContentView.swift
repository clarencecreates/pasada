import SwiftUI
import UIKit
import PhotosUI

struct ContentView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var placard: Placard
    private let onClose: (() -> Void)?
    @State private var sign: SignDraft
    @State private var selectedID: UUID?
    @State private var dragLayerID: UUID?
    @State private var dragOrigin: CGPoint?
    /// Font size and box width when a corner drag or pinch began. Both are
    /// scaled by the same factor so the line keeps its wrapping while it grows.
    @State private var scaleOrigin: (size: Double, width: Double)?
    @State private var selectedWidthStart: Double?
    @State private var selectedRotationStart: Double?
    @State private var canvasZoom: CGFloat = 1
    @State private var canvasZoomStart: CGFloat = 1
    @State private var canvasCameraOffset: CGSize = .zero
    @State private var canvasCameraOffsetStart: CGSize = .zero
    @State private var canvasPanStart: CGSize = .zero
    @State private var isMagnifyingCanvas = false
    @State private var alignmentGuideX: CGFloat?
    @State private var alignmentGuideY: CGFloat?
    @State private var showsCurveControls = false
    @State private var showsSpacingControls = false
    @State private var showsFontSizeControls = false
    @State private var showsColorControls = false
    @State private var showsFontFamilyControls = false
    @State private var showsFontStyleControls = false
    @State private var photoSelection: PhotosPickerItem?
    // Counters that only exist to fire haptics.
    @State private var deleteTick = 0
    @State private var addTick = 0
    @State private var historyTick = 0
    @State private var imageImportError: String?
    @State private var history: [SignDraft]
    @State private var historyIndex: Int
    @State private var focusedLayer: UUID?

    init(placard: Binding<Placard>, onClose: (() -> Void)? = nil) {
        _placard = placard
        self.onClose = onClose
        // Library loading migrates stored PSD templates, but the editor can be
        // created from an in-memory placard retained by an older app run. Apply
        // the same repair here before a raster layer becomes live editable text.
        // Imported PSD lines are converted to ordinary text up front, so the
        // canvas never swaps a raster preview for live text mid-edit.
        let migratedSign = placard.wrappedValue.sign.applyingImportedPSDLayout().bakingImportedPSDType()
        _sign = State(initialValue: migratedSign)
        _history = State(initialValue: [migratedSign])
        _historyIndex = State(initialValue: 0)
    }

    var body: some View {
        ZStack {
            // The empty editor workspace is a real hit target, including the
            // space outside the placard. It sits behind the canvas controls.
            Color.widyipBackground
                .overlay { PlacardGlow(sign: sign) }
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: handleCanvasBackgroundTap)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: handleCanvasBackgroundTap)
                canvas
                Spacer(minLength: 0)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: handleCanvasBackgroundTap)
            }
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // The workspace includes the black area around the placard, so
            // camera gestures belong to the entire editor rather than only the
            // artboard-sized canvas view.
            // Pinch zooms the camera, or resizes the selected line when there is one.
            .simultaneousGesture(cameraMagnifyGesture(canvasSize: workspaceCanvasSize))
            .simultaneousGesture(
                cameraPanGesture(canvasSize: workspaceCanvasSize),
                including: selectedID == nil ? .all : .none
            )
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) { formattingBar }
            // The top stays clear for the placard; only a way back floats there.
            .overlay(alignment: .top) { topControls }
            .onChange(of: photoSelection) { _, item in
                guard let item else { return }
                Task { await addImage(from: item) }
            }
            // Haptics: a tick on selection, a bump when a line snaps to the
            // centre guides, and taps for add, delete, undo and redo.
            .sensoryFeedback(.selection, trigger: selectedID) { _, new in new != nil }
            .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: alignmentGuideX != nil) { _, snapped in snapped }
            .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: alignmentGuideY != nil) { _, snapped in snapped }
            .sensoryFeedback(.impact(weight: .medium), trigger: addTick)
            .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.9), trigger: deleteTick)
            .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: historyTick)
            .alert("Couldn't add image", isPresented: Binding(
                get: { imageImportError != nil },
                set: { if !$0 { imageImportError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(imageImportError ?? "")
            }
    }

    private var formattingBar: some View {
        ZStack(alignment: .bottom) {
            if let id = selectedID, let layer = sign.layers.first(where: { $0.id == id }) {
                editorToolRail(id: id, layer: layer)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                HStack(spacing: 10) {
                    Button(action: addTextLayer) {
                        Label("Add text", systemImage: "textformat")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 20)
                            .frame(height: 48)
                    }
                    .buttonStyle(.plain)
                    .editorGlass(Capsule())

                    // The system picker runs out of process, so no photo-library
                    // permission prompt is needed.
                    PhotosPicker(selection: $photoSelection, matching: .images) {
                        Label("Add image", systemImage: "photo")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 20)
                            .frame(height: 48)
                    }
                    .buttonStyle(.plain)
                    .editorGlass(Capsule())
                }
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: selectedID)
    }

    private func editorToolRail(id: UUID, layer: TextLayer) -> some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {

                    // Popovers rather than menus, so the choices open above the
                    // rail like every other tool instead of covering it.
                    Button { showsFontFamilyControls.toggle() } label: {
                        EditorToolLabel(symbol: "textformat", title: "Font", showTitle: focusedLayer != id)
                    }
                    .popover(isPresented: $showsFontFamilyControls, arrowEdge: .bottom) {
                        OptionList(options: SignFontFamily.allCases, selection: layer.resolvedFontFamily, title: \.title) { family in
                            update(id) { $0.fontFamily = family }
                            showsFontFamilyControls = false
                        }
                        .presentationCompactAdaptation(.popover)
                    }

                    Button { showsFontStyleControls.toggle() } label: {
                        EditorToolLabel(symbol: "character.textbox", title: "Font style", showTitle: focusedLayer != id)
                    }
                    .popover(isPresented: $showsFontStyleControls, arrowEdge: .bottom) {
                        OptionList(options: SignFont.allCases, selection: layer.font, title: \.title) { style in
                            update(id) { $0.font = style }
                            showsFontStyleControls = false
                        }
                        .presentationCompactAdaptation(.popover)
                    }

                    Button { showsFontSizeControls.toggle() } label: {
                        EditorToolLabel(symbol: "textformat.size", title: "Font size", showTitle: focusedLayer != id)
                    }
                    .popover(isPresented: $showsFontSizeControls, arrowEdge: .bottom) {
                        FontSizeControl(
                            value: liveBinding(for: id, \.size),
                            onEditingEnded: recordCurrentState,
                            onDecrease: { update(id) { $0.size = max(0.10, $0.size - 0.01) } },
                            onIncrease: { update(id) { if $0.size < 3.00 { $0.size = min(3.00, $0.size + 0.01) } } }
                        )
                        .presentationCompactAdaptation(.popover)
                    }

                    Button { showsColorControls.toggle() } label: {
                        EditorFontColorLabel(color: layer.color.color, title: "Font color", showTitle: focusedLayer != id)
                    }
                    .accessibilityLabel("Font color")
                    .popover(isPresented: $showsColorControls, arrowEdge: .bottom) {
                        FontColorControl(selection: colorBinding(for: id, gradient: false))
                            .presentationCompactAdaptation(.popover)
                    }

                    Button { showsCurveControls.toggle() } label: {
                        EditorToolLabel(symbol: "textformat", title: "Curve", isCurved: true, showTitle: focusedLayer != id)
                    }
                    .transition(.opacity)
                    .popover(isPresented: $showsCurveControls, arrowEdge: .bottom) {
                        CurveControl(
                            value: liveBinding(for: id, \.curve),
                            onEditingEnded: recordCurrentState
                        )
                        .presentationCompactAdaptation(.popover)
                    }

                    Button { showsSpacingControls.toggle() } label: {
                        EditorToolLabel(symbol: "text.line.first.and.arrowtriangle.forward", title: "Spacing", showTitle: focusedLayer != id)
                    }
                    .popover(isPresented: $showsSpacingControls, arrowEdge: .bottom) {
                        SpacingControl(
                            letterSpacing: liveBinding(for: id, \.letterSpacing),
                            lineSpacing: liveBinding(for: id, \.lineSpacing),
                            onEditingEnded: recordCurrentState
                        )
                        .presentationCompactAdaptation(.popover)
                    }

                    Button(action: addTextLayer) {
                        EditorToolLabel(symbol: "plus.square", title: "Add text", showTitle: focusedLayer != id)
                    }
                    .transition(.opacity)
                }
                .padding(.leading, 8)
                .padding(.vertical, 7)
            }

            Button(action: dismissSelectionBar) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 48, height: 48)
                        .background(.background, in: Circle())
                        .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
                }
                .padding(.horizontal, 8)
                .accessibilityLabel("Finish editing")
        }
        .editorRail()
    }


    private var canvas: some View {
        GeometryReader { proxy in
            ZStack {
                SignRenderer(sign: sign, selectedID: selectedID)
                    .allowsHitTesting(false)

                alignmentGuides(in: proxy.size)

                // One surface owns canvas touches and resolves which line they
                // belong to, so overlapping text boxes can never fight over a drag.
                Color.clear
                    .contentShape(Rectangle())
                    // A tap only counts when the finger didn't move; any movement is a drag.
                    .gesture(textDragGesture(in: proxy.size).exclusively(before: canvasTapGesture(in: proxy.size)))

                if let selectedID, let frame = contentFrame(of: selectedID, in: proxy.size) {
                    let text = sign.layers.first(where: { $0.id == selectedID })
                    TransformSelection(contentSize: frame.size, rotation: frame.rotation,
                                       // Only text has a wrapping box to resize from the sides.
                                       widthHandles: text.map { WidthHandles(startWidth: $0.width ?? 0.88, stretch: $0.resolvedHorizontalScale) },
                                       canvasSize: proxy.size, zoom: canvasZoom, widthStart: $selectedWidthStart, rotationStart: $selectedRotationStart,
                                       onScale: { factor in scaleSelectedLayer(by: factor) },
                                       onScaleEnd: endScaling,
                                       onWidthResize: { newWidth in updateLive(selectedID) { $0.width = min(4, max(0.05, newWidth)) } },
                                       onWidthResizeEnd: recordCurrentState,
                                       onRotate: { degrees in
                                           updateLive(selectedID) { $0.rotation = degrees }
                                           updateImageLive(selectedID) { $0.rotation = degrees }
                                       },
                                       onRotateEnd: recordCurrentState)
                        .position(frame.center)
                }

                if let focusedLayer,
                   let layer = sign.layers.first(where: { $0.id == focusedLayer }) {
                    let textTarget = EditorTextGeometry.hitTarget(for: layer, canvasSize: proxy.size)
                    let editorFont = CanvasTypography.uiFont(
                        for: layer,
                        size: CanvasTypography.pointSize(layer.size, canvasWidth: proxy.size.width)
                    )
                    NativeTextSelectionEditor(text: binding(for: layer.id, \.text), font: editorFont) {
                        self.focusedLayer = nil
                    }
                    .frame(width: textTarget.size.width, height: textTarget.size.height)
                    .position(textTarget.center)
                    .rotationEffect(.degrees(textTarget.rotation))
                }
            }
            // Treat the placard as a fixed world and move the viewport toward
            // the user's pinch point, rather than resizing the placard model.
            .scaleEffect(canvasZoom)
            .offset(canvasCameraOffset)
        }
        .aspectRatio(2, contentMode: .fit)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func clampedCameraOffset(_ proposed: CGSize, zoom: CGFloat, canvasSize: CGSize) -> CGSize {
        guard zoom > 1.001 else {
            canvasCameraOffsetStart = .zero
            canvasPanStart = .zero
            return .zero
        }
        let maxX = canvasSize.width * (zoom - 1) / 2
        let maxY = canvasSize.height * (zoom - 1) / 2
        return CGSize(
            width: min(maxX, max(-maxX, proposed.width)),
            height: min(maxY, max(-maxY, proposed.height))
        )
    }

    private func cameraPanGesture(canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                // Text transforms keep exclusive ownership whenever a layer is
                // selected. The unselected, zoomed canvas becomes the camera.
                guard selectedID == nil, dragLayerID == nil, canvasZoom > 1.001, !isMagnifyingCanvas else { return }
                canvasCameraOffset = clampedCameraOffset(
                    CGSize(
                        width: canvasPanStart.width + value.translation.width,
                        height: canvasPanStart.height + value.translation.height
                    ),
                    zoom: canvasZoom,
                    canvasSize: canvasSize
                )
            }
            .onEnded { value in
                guard selectedID == nil, canvasZoom > 1.001, !isMagnifyingCanvas else { return }
                let projected = CGSize(
                    width: canvasPanStart.width + value.predictedEndTranslation.width,
                    height: canvasPanStart.height + value.predictedEndTranslation.height
                )
                let destination = clampedCameraOffset(projected, zoom: canvasZoom, canvasSize: canvasSize)
                withAnimation(.interpolatingSpring(stiffness: 260, damping: 34)) {
                    canvasCameraOffset = destination
                }
                canvasCameraOffsetStart = destination
                canvasPanStart = destination
            }
    }

    private func canvasTapGesture(in size: CGSize) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard let id = layerID(at: value.location, in: size) else {
                    handleCanvasBackgroundTap()
                    return
                }
                withAnimation(.easeInOut(duration: 0.24)) {
                    // A tap selects a line; tapping the selected line again types into it.
                    if selectedID == id {
                        if sign.layers.contains(where: { $0.id == id }) { focusedLayer = id }
                    } else {
                        selectedID = id
                        focusedLayer = nil
                    }
                }
            }
    }

    /// The layer under a touch. Text is drawn above images, so it is checked
    /// first. Within a kind, where padded boxes overlap, the box containing the
    /// point most centrally wins, not whichever was drawn last.
    private func layerID(at point: CGPoint, in size: CGSize) -> UUID? {
        let candidates = [sign.layers.reversed().map(\.id), sign.imageLayers.reversed().map(\.id)]
        for ids in candidates {
            var best: (id: UUID, depth: CGFloat)?
            for id in ids {
                guard let frame = contentFrame(of: id, in: size) else { continue }
                let padding = EditorTextGeometry.touchPadding
                let target = (
                    size: CGSize(width: frame.size.width + padding, height: frame.size.height + padding),
                    center: frame.center,
                    rotation: frame.rotation
                )
                guard targetContains(point, target: target) else { continue }
                let local = localPoint(point, in: target)
                let depth = max(abs(local.x) / (target.size.width / 2), abs(local.y) / (target.size.height / 2))
                if best == nil || depth < best!.depth { best = (id, depth) }
            }
            if let best { return best.id }
        }
        return nil
    }

    /// The drawn box of any layer in canvas points: measured text, or an image
    /// sized by its aspect ratio. Hit-testing and the selection box share it.
    private func contentFrame(of id: UUID, in size: CGSize) -> (size: CGSize, center: CGPoint, rotation: Double)? {
        if let text = sign.layers.first(where: { $0.id == id }) {
            return (
                EditorTextGeometry.textSize(for: text, canvasSize: size),
                CGPoint(x: text.x * size.width, y: text.y * size.height),
                text.rotation
            )
        }
        if let image = sign.imageLayers.first(where: { $0.id == id }) {
            let width = size.width * image.width
            return (
                CGSize(width: width, height: width * image.aspectRatio),
                CGPoint(x: image.x * size.width, y: image.y * size.height),
                image.rotation
            )
        }
        return nil
    }

    private func localPoint(
        _ point: CGPoint,
        in target: (size: CGSize, center: CGPoint, rotation: Double)
    ) -> CGPoint {
        let translatedX = point.x - target.center.x
        let translatedY = point.y - target.center.y
        let radians = -target.rotation * .pi / 180
        return CGPoint(
            x: translatedX * cos(radians) - translatedY * sin(radians),
            y: translatedX * sin(radians) + translatedY * cos(radians)
        )
    }

    private func targetContains(
        _ point: CGPoint,
        target: (size: CGSize, center: CGPoint, rotation: Double)
    ) -> Bool {
        let local = localPoint(point, in: target)
        return abs(local.x) <= target.size.width / 2 && abs(local.y) <= target.size.height / 2
    }


    private var workspaceCanvasSize: CGSize {
        let width = max(1, UIScreen.main.bounds.width - 28)
        return CGSize(width: width, height: width / 2)
    }

    private func cameraMagnifyGesture(canvasSize: CGSize) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0)
            .onChanged { value in
                if selectedID != nil {
                    scaleSelectedLayer(by: Double(value.magnification))
                    return
                }
                isMagnifyingCanvas = true
                let zoom = min(3, max(1, canvasZoomStart * value.magnification))
                let focalPoint = CGPoint(
                    x: value.startAnchor.x * canvasSize.width,
                    y: value.startAnchor.y * canvasSize.height
                )
                let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                let zoomChange = zoom / canvasZoomStart
                canvasZoom = zoom
                canvasCameraOffset = clampedCameraOffset(CGSize(
                    width: canvasCameraOffsetStart.width + (center.x - focalPoint.x) * (zoomChange - 1),
                    height: canvasCameraOffsetStart.height + (center.y - focalPoint.y) * (zoomChange - 1)
                ), zoom: zoom, canvasSize: canvasSize)
            }
            .onEnded { _ in
                if scaleOrigin != nil {
                    endScaling()
                    return
                }
                guard isMagnifyingCanvas else { return }
                canvasZoomStart = canvasZoom
                canvasCameraOffsetStart = canvasCameraOffset
                canvasPanStart = canvasCameraOffset
                isMagnifyingCanvas = false
            }
    }

    /// Uniformly scales the selected line relative to where the gesture began.
    /// Size and wrapping width move together, so text never reflows mid-drag.
    private func scaleSelectedLayer(by factor: Double) {
        guard let id = selectedID else { return }
        if let image = sign.imageLayers.first(where: { $0.id == id }) {
            let origin = scaleOrigin ?? (1, image.width)
            scaleOrigin = origin
            let clamped = min(3.0 / origin.width, max(0.05 / origin.width, factor))
            updateImageLive(id) { $0.width = origin.width * clamped }
            return
        }
        guard let layer = sign.layers.first(where: { $0.id == id }) else { return }
        // A nil width renders in the default 0.88 box; pin it so scaling is exact.
        let origin = scaleOrigin ?? (layer.size, layer.width ?? 0.88)
        scaleOrigin = origin
        let lower = max(0.10 / origin.size, 0.05 / origin.width)
        let upper = min(12.00 / origin.size, 4.0 / origin.width)
        let clamped = min(upper, max(lower, factor))
        updateLive(id) {
            $0.size = origin.size * clamped
            $0.width = origin.width * clamped
        }
    }

    private func endScaling() {
        guard scaleOrigin != nil else { return }
        scaleOrigin = nil
        recordCurrentState()
    }

    /// Dragging any line moves it, selecting it first if needed, with centre snapping.
    private func textDragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragLayerID == nil {
                    guard let id = layerID(at: value.startLocation, in: size),
                          let frame = contentFrame(of: id, in: size) else { return }
                    dragLayerID = id
                    dragOrigin = CGPoint(x: frame.center.x / size.width, y: frame.center.y / size.height)
                    if selectedID != id {
                        withAnimation(.easeInOut(duration: 0.2)) { selectedID = id }
                    }
                    focusedLayer = nil
                }
                guard let id = dragLayerID, let origin = dragOrigin else { return }
                let rawX = min(0.92, max(0.08, origin.x + value.translation.width / size.width))
                let rawY = min(0.86, max(0.14, origin.y + value.translation.height / size.height))
                let snapDistance: CGFloat = 10
                let snapsX = abs(rawX - 0.5) * size.width <= snapDistance
                let snapsY = abs(rawY - 0.5) * size.height <= snapDistance

                alignmentGuideX = snapsX ? size.width / 2 : nil
                alignmentGuideY = snapsY ? size.height / 2 : nil
                let x = snapsX ? 0.5 : Double(rawX)
                let y = snapsY ? 0.5 : Double(rawY)
                updateLive(id) { $0.x = x; $0.y = y }
                updateImageLive(id) { $0.x = x; $0.y = y }
            }
            .onEnded { _ in
                guard dragLayerID != nil else { return }
                dragLayerID = nil
                dragOrigin = nil
                alignmentGuideX = nil
                alignmentGuideY = nil
                recordCurrentState()
            }
    }

    @ViewBuilder private func alignmentGuides(in size: CGSize) -> some View {
        if let alignmentGuideX {
            Color.pink.opacity(0.9)
                .frame(width: 1, height: size.height)
                .position(x: alignmentGuideX, y: size.height / 2)
                .allowsHitTesting(false)
        }
        if let alignmentGuideY {
            Color.pink.opacity(0.9)
                .frame(width: size.width, height: 1)
                .position(x: size.width / 2, y: alignmentGuideY)
                .allowsHitTesting(false)
        }
    }

    private func addTextLayer() {
        let sourceLayer = selectedID.flatMap { id in sign.layers.first { $0.id == id } }
        let layer = TextLayer(
            text: "NEW TEXT",
            font: sourceLayer?.font ?? .wide,
            fontFamily: sourceLayer?.fontFamily ?? .cubao,
            size: sourceLayer?.size ?? 0.36,
            x: 0.5,
            y: 0.5,
            color: sourceLayer?.color ?? .lime,
            gradientColor: sourceLayer?.gradientColor ?? .pink,
            usesGradient: sourceLayer?.usesGradient ?? false,
            width: sourceLayer?.width
        )
        sign.layers.append(layer)
        recordCurrentState()
        addTick += 1
        // New text opens straight into the keyboard with the compact tools.
        withAnimation(.easeInOut(duration: 0.3)) {
            selectedID = layer.id
            focusedLayer = layer.id
        }
    }

    private func addImage(from item: PhotosPickerItem) async {
        defer { photoSelection = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw PlacardImageStore.ImportError.unreadable
            }
            let stored = try await Task.detached(priority: .userInitiated) {
                try PlacardImageStore.importImage(data)
            }.value
            // Start centred, at most 40% of the placard's width and 70% of its height.
            let layer = ImageLayer(
                assetID: stored.assetID,
                width: min(0.4, 0.35 / stored.aspectRatio),
                aspectRatio: stored.aspectRatio
            )
            sign.imageLayers.append(layer)
            recordCurrentState()
            addTick += 1
            withAnimation(.easeInOut(duration: 0.3)) {
                focusedLayer = nil
                selectedID = layer.id
            }
        } catch {
            imageImportError = error.localizedDescription
        }
    }


    /// Deletes the selected text or image. An image's file stays until the
    /// library's cleanup, so undo can still bring it back.
    private func deleteSelectedLayer() {
        guard let id = selectedID else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            focusedLayer = nil
            selectedID = nil
            sign.layers.removeAll { $0.id == id }
            sign.imageLayers.removeAll { $0.id == id }
        }
        recordCurrentState()
        deleteTick += 1
    }

    private func handleCanvasBackgroundTap() {
        guard selectedID != nil || focusedLayer != nil else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            selectedID = nil
            focusedLayer = nil
        }
    }

    private func dismissSelectionBar() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            focusedLayer = nil
            selectedID = nil
        }
    }

    /// Commits the draft to the library. The library pushes it on to the
    /// widget only when this placard is the equipped one.
    private func save() {
        placard.sign = sign
    }

    private func close() {
        save()
        focusedLayer = nil
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private var topControls: some View {
        HStack {
            HStack(spacing: 0) {
                Button(action: close) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to placards")
            }
            .editorGlass(Circle())

            Spacer()

            if selectedID != nil {
                Button(action: deleteSelectedLayer) {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.red)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .editorGlass(Circle())
                .accessibilityLabel("Delete")
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }

            HStack(spacing: 0) {
                Button(action: undo) {
                    Image(systemName: "arrow.uturn.backward")
                        .frame(width: 44, height: 44)
                }
                .disabled(historyIndex == 0)
                .accessibilityLabel("Undo")
                Button(action: redo) {
                    Image(systemName: "arrow.uturn.forward")
                        .frame(width: 44, height: 44)
                }
                .disabled(historyIndex >= history.count - 1)
                .accessibilityLabel("Redo")
            }
            .font(.system(size: 15, weight: .semibold))
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
            .editorGlass(Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selectedID != nil)
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

    private func updateImageLive(_ id: UUID, _ change: (inout ImageLayer) -> Void) {
        guard let index = sign.imageLayers.firstIndex(where: { $0.id == id }) else { return }
        change(&sign.imageLayers[index])
    }

    private func recordCurrentState() {
        if history[historyIndex] == sign { return }
        history = Array(history.prefix(historyIndex + 1))
        history.append(sign)
        historyIndex = history.count - 1
        // Every committed step is saved, so there is no Save button to forget.
        save()
    }

    private func undo() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        sign = history[historyIndex]
        historyTick += 1
        save()
    }

    private func redo() {
        guard historyIndex < history.count - 1 else { return }
        historyIndex += 1
        sign = history[historyIndex]
        historyTick += 1
        save()
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

    private func binding<Value: Equatable>(for id: UUID, _ keyPath: WritableKeyPath<TextLayer, Value>) -> Binding<Value> {
        Binding(
            get: { sign.layers.first(where: { $0.id == id })![keyPath: keyPath] },
            set: { newValue in
                // TextField can emit its current value again when it receives
                // focus. Selection must not discard the PSD preview or alter a
                // layer until the user has genuinely changed its contents.
                guard sign.layers.first(where: { $0.id == id })?[keyPath: keyPath] != newValue else { return }
                update(id) { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    private func liveBinding<Value>(for id: UUID, _ keyPath: WritableKeyPath<TextLayer, Value>) -> Binding<Value> {
        Binding(
            get: { sign.layers.first(where: { $0.id == id })![keyPath: keyPath] },
            set: { newValue in updateLive(id) { $0[keyPath: keyPath] = newValue } }
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

private struct EditorToolLabel: View {
    let symbol: String
    let title: String
    var tint: Color = .primary
    var isCurved = false
    var showTitle = true

    var body: some View {
        VStack(spacing: 5) {
            if isCurved {
                CurveFormattingIcon(isActive: false)
                    .frame(height: 27)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(height: 27)
            }

            if showTitle {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .transition(.opacity)
            }
        }
        .frame(width: 70, height: showTitle ? 52 : 34)
        .contentShape(Rectangle())
    }
}

private struct EditorFontColorLabel: View {
    let color: Color
    let title: String
    var showTitle = true

    var body: some View {
        VStack(spacing: 5) {
            VStack(spacing: 1) {
                Text("A")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.primary)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: 25, height: 4)
            }
            .frame(height: 27)

            if showTitle {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .transition(.opacity)
            }
        }
        .frame(width: 70, height: showTitle ? 52 : 34)
        .contentShape(Rectangle())
    }
}

/// A short list of choices with a checkmark on the current one.
private struct OptionList<Option: Identifiable & Equatable>: View {
    let options: [Option]
    let selection: Option
    let title: KeyPath<Option, String>
    let choose: (Option) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(options) { option in
                Button { choose(option) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .semibold))
                            .opacity(option == selection ? 1 : 0)
                        Text(option[keyPath: title])
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 46)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 200)
        .padding(.vertical, 6)
    }
}

private struct FontColorControl: View {
    @Binding var selection: Color

    private let jeepneyColors: [Color] = [
        .black,
        .white,
        Color(red: 1, green: 0.08, blue: 0.08),
        Color(red: 1, green: 0.84, blue: 0.11),
        SignColor.lime.color,
        SignColor.pink.color,
        Color(red: 1, green: 0.57, blue: 0.05),
        Color(red: 0.04, green: 0.78, blue: 0.88)
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ColorPicker("Custom color", selection: $selection, supportsOpacity: false)
                    .labelsHidden()
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.primary)
                            .allowsHitTesting(false)
                    }
                    .frame(width: 38, height: 38)

                ForEach(Array(jeepneyColors.enumerated()), id: \.offset) { _, color in
                    Button {
                        selection = color
                    } label: {
                        Circle()
                            .fill(color)
                            .frame(width: 34, height: 34)
                            .overlay {
                                Circle()
                                    .stroke(Color(uiColor: .separator), lineWidth: 0.75)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Choose preset color")
                }
            }
            .padding(14)
        }
        .frame(width: 340)
    }
}

private struct CurveControl: View {
    @Binding var value: Double
    let onEditingEnded: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .foregroundStyle(.secondary)
            Slider(value: $value, in: -1...1, step: 0.01) { editing in
                if !editing { onEditingEnded() }
            }
            .tint(SelectionStyle.color)
            Image(systemName: "arrow.up.right.and.arrow.down.left")
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 290)
    }
}

private struct SpacingControl: View {
    @Binding var letterSpacing: Double
    @Binding var lineSpacing: Double
    let onEditingEnded: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            spacingRow(
                title: "Letter spacing",
                value: $letterSpacing,
                range: -0.08...0.24,
                display: "\(Int((letterSpacing * 100).rounded()))"
            )
            spacingRow(
                title: "Line spacing",
                value: $lineSpacing,
                range: 0...1.2,
                display: String(format: "%.1f", 1 + lineSpacing)
            )
        }
        .padding(20)
        .frame(width: 320)
    }

    private func spacingRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        display: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            HStack(spacing: 14) {
                Slider(value: value, in: range, step: 0.01) { editing in
                    if !editing { onEditingEnded() }
                }
                .tint(SelectionStyle.color)
                Text(display)
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 56, height: 46)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color(uiColor: .separator), lineWidth: 1)
                    }
            }
        }
    }
}

private struct FontSizeControl: View {
    @Binding var value: Double
    let onEditingEnded: () -> Void
    let onDecrease: () -> Void
    let onIncrease: () -> Void

    private var sliderValue: Binding<Double> {
        Binding(
            get: { min(3.00, max(0.10, value)) },
            set: { value = $0 }
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onDecrease) {
                Image(systemName: "minus")
                    .frame(width: 28, height: 36)
            }

            Slider(value: sliderValue, in: 0.10...3.00, step: 0.005) { editing in
                if !editing { onEditingEnded() }
            }
            .tint(SelectionStyle.color)

            Text("\(value * 100, specifier: "%.1f")")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: 40)

            Button(action: onIncrease) {
                Image(systemName: "plus")
                    .frame(width: 28, height: 36)
            }
        }
        .font(.body.weight(.medium))
        .padding(16)
        .frame(width: 300)
    }
}

private struct FormattingIcon: View {
    let symbol: String
    var isActive = false
    var tint: Color? = nil

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(tint ?? (isActive ? Color.accentColor : Color.primary))
            .frame(width: 36, height: 36)
            .background(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
    }
}

private struct CurveFormattingIcon: View {
    let isActive: Bool

    var body: some View {
        HStack(spacing: -1) {
            ForEach(Array("ABC").indices, id: \.self) { index in
                Text(String(Array("ABC")[index]))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .rotationEffect(.degrees(Double(index - 1) * 12))
                    .offset(y: index == 1 ? -4 : 0)
            }
        }
        .foregroundStyle(isActive ? Color.accentColor : Color.primary)
        .frame(width: 36, height: 36)
        .background(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
    }
}

private enum SelectionStyle {
    static let color = Color(red: 1, green: 0.4, blue: 196.0 / 255.0)
}

enum EditorTextGeometry {
    /// Padding around the measured text that stays touchable.
    static let touchPadding: CGFloat = 10

    static func hitTarget(for layer: TextLayer, canvasSize: CGSize) -> (size: CGSize, center: CGPoint, rotation: Double) {
        let text = textSize(for: layer, canvasSize: canvasSize)
        return (
            CGSize(width: text.width + touchPadding, height: text.height + touchPadding),
            CGPoint(x: layer.x * canvasSize.width, y: layer.y * canvasSize.height),
            layer.rotation
        )
    }

    /// The drawn size of a line, measured with the same font, tracking, line
    /// spacing and wrapping box that `PlacardText` renders with.
    static func textSize(for layer: TextLayer, canvasSize: CGSize) -> CGSize {
        let fontSize = CanvasTypography.pointSize(layer.size, canvasWidth: canvasSize.width)
        let font = CanvasTypography.uiFont(for: layer, size: fontSize)
        let box = canvasSize.width * CGFloat(layer.width ?? 0.88)
        let text = layer.text.isEmpty ? " " : layer.text.uppercased()

        let stretch = CGFloat(layer.resolvedHorizontalScale)

        if layer.glyphOffsets != nil {
            return CGSize(width: box * stretch, height: fontSize * 1.7)
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = fontSize * layer.lineSpacing
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .kern: fontSize * layer.letterSpacing,
            .paragraphStyle: paragraph
        ]

        if abs(layer.curve) > 0.01 {
            let arc = CurvedTextLayout(layer: layer, fontSize: fontSize).size
            return CGSize(width: arc.width * stretch, height: arc.height)
        }

        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: box, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
        return CGSize(width: min(box, ceil(bounds.width)) * stretch, height: max(18, ceil(bounds.height)))
    }
}

private struct NativeTextSelectionEditor: UIViewRepresentable {
    @Binding var text: String
    let font: UIFont
    let onResign: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// Asks for the keyboard once it is actually in a window. Asking any
    /// earlier (as soon as it is created) is ignored by UIKit, which is why a
    /// freshly added line would otherwise open without a keyboard.
    final class FocusingTextView: UITextView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { becomeFirstResponder() }
        }
    }

    func makeUIView(context: Context) -> UITextView {
        let view = FocusingTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textColor = .clear
        view.tintColor = .systemBlue
        view.font = font
        view.textAlignment = .center
        view.text = text
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.autocorrectionType = .no
        view.autocapitalizationType = .allCharacters
        view.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
        if view.font != font { view.font = font }
        if !view.isFirstResponder {
            DispatchQueue.main.async { view.becomeFirstResponder() }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NativeTextSelectionEditor

        init(parent: NativeTextSelectionEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.onResign()
        }
    }
}

private enum ResizeCorner: Hashable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing
}

/// Side handles for text: the wrapping width when the drag began and the
/// line's horizontal stretch, which maps the box edge back to model width.
private struct WidthHandles {
    let startWidth: Double
    let stretch: Double
}

private struct TransformSelection: View {
    /// Size of the selected content in canvas points.
    let contentSize: CGSize
    let rotation: Double
    /// Present for text, whose wrapping box can be resized from the sides.
    let widthHandles: WidthHandles?
    let canvasSize: CGSize
    /// Canvas zoom, so screen-space finger travel converts to canvas points.
    let zoom: CGFloat
    @Binding var widthStart: Double?
    @Binding var rotationStart: Double?
    @State private var snappedRotation: Double?
    @State private var activeResizeCorners: Set<ResizeCorner> = []
    @State private var activeWidthHandle: Double?
    /// The corner that owns an in-progress scale, and the box size it started from.
    @State private var drivingCorner: ResizeCorner?
    @State private var scaleStartBox: CGSize?
    let onScale: (Double) -> Void
    let onScaleEnd: () -> Void
    let onWidthResize: (Double) -> Void
    let onWidthResizeEnd: () -> Void
    let onRotate: (Double) -> Void
    let onRotateEnd: () -> Void

    // The box is the drawn content plus a small margin, the same geometry the
    // canvas uses for hit-testing, so what is outlined is what is touchable.
    private var boxWidth: CGFloat { contentSize.width + 8 }
    private var boxHeight: CGFloat { max(30, contentSize.height + 8) }
    private var selectionRotation: Double { rotation }
    private var interactionHeight: CGFloat { boxHeight + 120 }
    private let handleSize: CGFloat = 11
    private var isTwoCornerResize: Bool { activeResizeCorners.count > 1 }

    var body: some View {
        ZStack {
            selectionChrome
                .rotationEffect(.degrees(selectionRotation))

            if rotationStart != nil {
                Text("\(normalizedDegrees)°")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .overlay { Capsule().stroke(.white.opacity(0.7), lineWidth: 0.5) }
                    .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
                    .offset(y: -boxHeight / 2 - 28)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: boxWidth, height: interactionHeight)
        // Only the handles are touchable here. The box interior falls through to
        // the canvas, which owns moving, tapping and pinching.
        .coordinateSpace(name: "selection")
        .sensoryFeedback(.impact(weight: .medium, intensity: 0.8), trigger: snappedRotation) { _, new in new != nil }
        .sensoryFeedback(.selection, trigger: drivingCorner) { _, new in new != nil }
        .sensoryFeedback(.selection, trigger: activeWidthHandle) { _, new in new != nil }
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var selectionChrome: some View {
        ZStack {
            Rectangle()
                .stroke(SelectionStyle.color, lineWidth: 1)
                .allowsHitTesting(false)

            if rotationStart == nil {
                cornerHandle(.topLeading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .offset(x: -handleSize / 2, y: -handleSize / 2)
                cornerHandle(.topTrailing)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .offset(x: handleSize / 2, y: -handleSize / 2)
                cornerHandle(.bottomLeading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .offset(x: -handleSize / 2, y: handleSize / 2)
                cornerHandle(.bottomTrailing)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .offset(x: handleSize / 2, y: handleSize / 2)

                if widthHandles != nil {
                    widthHandle(isActive: activeWidthHandle == -1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .offset(x: -4)
                        .gesture(widthGesture(direction: -1))
                        .opacity(activeResizeCorners.isEmpty && (activeWidthHandle == nil || activeWidthHandle == -1) ? 1 : 0)
                    widthHandle(isActive: activeWidthHandle == 1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .offset(x: 4)
                        .gesture(widthGesture(direction: 1))
                        .opacity(activeResizeCorners.isEmpty && (activeWidthHandle == nil || activeWidthHandle == 1) ? 1 : 0)
                }

                rotationHandle
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .offset(y: 44)
                    .gesture(rotationGesture)
            }
        }
        .frame(width: boxWidth, height: boxHeight)
    }

    @ViewBuilder private func cornerHandle(_ corner: ResizeCorner) -> some View {
        let isActive = activeResizeCorners.contains(corner)
        Circle()
            .fill(isActive ? SelectionStyle.color : .white)
            .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
            .frame(width: handleSize, height: handleSize)
            .background {
                if isActive && !isTwoCornerResize {
                    Circle()
                        .fill(.ultraThinMaterial.opacity(0.62))
                        .frame(width: 34, height: 34)
                        .shadow(color: .black.opacity(0.14), radius: 5, y: 2)
                        .allowsHitTesting(false)
                }
            }
        // Keep hidden handles touchable so two fingers that land together can
        // still form a two-corner transform, just like Canva's chrome.
        .opacity(
            activeWidthHandle != nil
                ? 0
                : (activeResizeCorners.isEmpty ? 1 : (isTwoCornerResize ? 0 : (isActive ? 1 : 0)))
        )
        .contentShape(Circle().inset(by: -8))
        .gesture(resizeGesture(corner: corner))
    }

    private var rotationHandle: some View {
        ZStack {
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
            Circle()
                .stroke(Color(uiColor: .separator), lineWidth: 1)
            Image(systemName: "rotate.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.black)
        }
        .frame(width: 24, height: 24)
        .contentShape(Circle())
    }

    private func widthHandle(isActive: Bool) -> some View {
        Capsule()
            .fill(isActive ? SelectionStyle.color : .white)
            .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
            .frame(width: 6, height: 18)
            .background {
                if isActive {
                    Circle()
                        .fill(.ultraThinMaterial.opacity(0.62))
                        .frame(width: 34, height: 34)
                        .shadow(color: .black.opacity(0.14), radius: 5, y: 2)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle().inset(by: -8))
    }

    private var normalizedDegrees: Int {
        let degrees = Int(rotation.rounded()) % 360
        return degrees > 180 ? degrees - 360 : (degrees < -180 ? degrees + 360 : degrees)
    }

    /// A finger translation in screen space, turned into the selection box's own
    /// (rotated) axes and canvas points. Measuring in global space matters: the
    /// handles move as the box resizes, so a local measurement feeds back on
    /// itself and makes the text jitter.
    private func boxLocal(_ translation: CGSize) -> CGPoint {
        let radians = -selectionRotation * .pi / 180
        let dx = translation.width / zoom, dy = translation.height / zoom
        return CGPoint(
            x: dx * cos(radians) - dy * sin(radians),
            y: dx * sin(radians) + dy * cos(radians)
        )
    }

    private func resizeGesture(corner: ResizeCorner) -> some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                activeResizeCorners.insert(corner)
                // With two fingers on two corners, the first one drives the scale.
                if drivingCorner == nil {
                    drivingCorner = corner
                    scaleStartBox = CGSize(width: boxWidth, height: boxHeight)
                }
                guard drivingCorner == corner, let box = scaleStartBox else { return }

                // Scale about the centre so the dragged corner stays under the finger:
                // project the drag onto the corner's outward diagonal.
                let signX: CGFloat = (corner == .topTrailing || corner == .bottomTrailing) ? 1 : -1
                let signY: CGFloat = (corner == .bottomLeading || corner == .bottomTrailing) ? 1 : -1
                let halfDiagonal = hypot(box.width, box.height) / 2
                let outward = CGPoint(x: signX * box.width / 2 / halfDiagonal, y: signY * box.height / 2 / halfDiagonal)
                let local = boxLocal(value.translation)
                let travel = local.x * outward.x + local.y * outward.y
                onScale(Double(max(0.05, (halfDiagonal + travel) / halfDiagonal)))
            }
            .onEnded { _ in
                activeResizeCorners.remove(corner)
                guard drivingCorner == corner else { return }
                drivingCorner = nil
                scaleStartBox = nil
                onScaleEnd()
            }
    }

    private func widthGesture(direction: Double) -> some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                guard let handles = widthHandles else { return }
                activeWidthHandle = direction
                let stretch = handles.stretch
                let start = widthStart ?? handles.startWidth
                widthStart = start
                // The box grows on both sides about its centre, so the edge under
                // the finger moves by the full drag: twice that in total width.
                let travel = Double(boxLocal(value.translation).x) * direction
                onWidthResize(start + 2 * travel / Double(canvasSize.width) / stretch)
            }
            .onEnded { _ in
                widthStart = nil
                activeWidthHandle = nil
                onWidthResizeEnd()
            }
    }

    private var rotationGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("selection"))
            .onChanged { value in
                let start = rotationStart ?? rotation
                rotationStart = start
                let center = CGPoint(x: boxWidth / 2, y: interactionHeight / 2)
                let startAngle = atan2(value.startLocation.y - center.y, value.startLocation.x - center.x)
                let currentAngle = atan2(value.location.y - center.y, value.location.x - center.x)
                var delta = currentAngle - startAngle
                if delta > .pi { delta -= 2 * .pi }
                if delta < -.pi { delta += 2 * .pi }
                let rawRotation = start + delta * 180 / .pi
                let nearestRightAngle = (rawRotation / 90).rounded() * 90

                if let snappedRotation {
                    if abs(rawRotation - snappedRotation) <= 9 {
                        onRotate(snappedRotation)
                    } else {
                        self.snappedRotation = nil
                        onRotate(rawRotation)
                    }
                } else if abs(rawRotation - nearestRightAngle) <= 4 {
                    snappedRotation = nearestRightAngle
                    onRotate(nearestRightAngle)
                } else {
                    onRotate(rawRotation)
                }
            }
            .onEnded { _ in
                rotationStart = nil
                snappedRotation = nil
                onRotateEnd()
            }
    }

}

private extension View {
    /// The floating capsule the editor's tool rails sit in.
    func editorRail() -> some View {
        self
            .tint(.primary)
            .editorGlass(Capsule())
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
    }
}

private extension View {
    /// Liquid Glass on iOS 26, frosted material with a hairline before that.
    @ViewBuilder func editorGlass<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.background { Color.clear.glassEffect(.regular, in: shape).allowsHitTesting(false) }
        } else {
            self
                .background(.regularMaterial, in: shape)
                .overlay { shape.stroke(.white.opacity(0.12), lineWidth: 0.5) }
        }
    }
}

/// A faint wash of the placard's own colours behind the canvas, fading to the
/// near-black edges. Gives the workspace depth without competing with the sign.
private struct PlacardGlow: View {
    let sign: SignDraft

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width * 1.3
            SignRenderer(sign: sign, cornerRadius: 40)
                .frame(width: width, height: width / 2)
                .blur(radius: 80)
                .saturation(1.4)
                .opacity(0.16)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        // The fade spans the whole screen, so the blur never shows a hard edge.
        .mask {
            RadialGradient(colors: [.black, .black.opacity(0.4), .clear], center: .center, startRadius: 0, endRadius: 460)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
