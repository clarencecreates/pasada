import SwiftUI
import CoreMotion
import WidgetKit

// The library is a FamPay-style card deck: swipe sideways to browse, drag the
// centered placard down into the slot to equip it, or up into the bin to delete.
struct PlacardLibraryView: View {
    @State private var placards = PlacardStore.load()
    @State private var editingPlacard: Placard?
    @State private var isChoosingTemplate = false

    // Carousel state. `position` is a fractional index so cards can sit between
    // stops mid-swipe; `gap` slides neighbors smoothly after inserts and removals.
    @State private var position: CGFloat = 0
    @State private var dragStartPosition: CGFloat = 0
    @State private var axis: DragAxis?
    @State private var verticalDrag: CGFloat = 0
    @State private var armed: DropZone?
    @State private var phase: CommitPhase = .idle
    @State private var dissolve: CGFloat = 0
    @State private var slotFlash: CGFloat = 0
    @State private var gapIndex: Int?
    @State private var gapAmount: CGFloat = 0

    @State private var pendingUndo: DeletedPlacard?
    @State private var reveal: Placard?
    @State private var equipCount = 0
    @State private var deleteCount = 0

    @AppStorage("equipped-placard-id") private var equippedID = ""
    @AppStorage("has-completed-onboarding") private var hasCompletedOnboarding = false
    @State private var isOnboarding = false
    /// The coach shown on the first visit after onboarding; any touch ends it.
    @State private var isCoaching = false
    @State private var coachStep: CoachStep = .tap
    @State private var coachFinger: CGPoint = .zero
    @State private var coachFingerVisible = false
    @State private var coachPressed = false
    @StateObject private var tilt = DeviceTiltObserver()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let metrics = CarouselMetrics(size: proxy.size)

            ZStack {
                if placards.isEmpty {
                    emptyState
                } else {
                    ambientGlow(metrics)
                    stage(metrics)
                }
                chrome(metrics)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .environment(\.colorScheme, .dark)
        .background(Color.widyipBackground.ignoresSafeArea())
        .overlay {
            if let selected = editingPlacard {
                // No NavigationStack: its hidden bar still swallowed taps at the
                // top of the screen, where the editor's back button lives.
                ContentView(
                    placard: binding(for: selected.id),
                    onClose: {
                        withAnimation(.easeInOut(duration: 0.28)) {
                            editingPlacard = nil
                        }
                    }
                )
                .environment(\.colorScheme, .dark)
                .transition(.move(edge: .trailing))
                .zIndex(10)
            }
        }
        .overlay {
            if let reveal {
                EquipRevealView(placard: reveal, done: finishReveal)
                    .environment(\.colorScheme, .dark)
                    .transition(.opacity)
                    .zIndex(20)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: editingPlacard?.id)
        .sheet(isPresented: $isChoosingTemplate) {
            TemplatePicker { sign in
                let newPlacard = Placard(sign: sign)
                placards.insert(newPlacard, at: 0)
                position = 0
                editingPlacard = newPlacard
                isChoosingTemplate = false
            }
        }
        .onChange(of: placards) { _, newValue in PlacardStore.save(newValue) }
        .onChange(of: placards.count) { _, count in
            position = min(position, CGFloat(max(0, count - 1)))
        }
        .task(id: pendingUndo?.placard.id) {
            guard pendingUndo != nil else { return }
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { pendingUndo = nil }
        }
        .task {
            // Drop image files no placard uses any more. Safe here: nothing can
            // restore a reference until an undo exists in this session.
            let referenced = Set((placards.map(\.sign) + [SignStore.load()]).flatMap(\.imageLayers).map(\.assetID))
            await Task.detached(priority: .background) {
                PlacardImageStore.removeUnreferenced(keeping: referenced)
            }.value
        }
        .onAppear {
            tilt.start()
            // First launch only. Someone who already has placards skips it.
            guard !hasCompletedOnboarding else { return }
            if placards.isEmpty {
                // Present without the slide-up, so the empty library never flashes.
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { isOnboarding = true }
            } else {
                hasCompletedOnboarding = true
            }
        }
        .fullScreenCover(isPresented: $isOnboarding) {
            OnboardingView { sign in
                placards.insert(Placard(sign: sign), at: 0)
                position = 0
                hasCompletedOnboarding = true
                isOnboarding = false
                isCoaching = true
            }
        }
        .onDisappear { tilt.stop() }
        .sensoryFeedback(.selection, trigger: focusedIndex)
        .sensoryFeedback(trigger: armed) { _, new in
            switch new {
            case .equip: .impact(weight: .medium, intensity: 0.9)
            case .delete: .impact(weight: .heavy, intensity: 1)
            case nil: nil
            }
        }
        .sensoryFeedback(.success, trigger: equipCount)
        .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.8), trigger: deleteCount)
    }

    // MARK: - Derived state

    /// Stops run 0...placards.count: every placard, then the "new placard" card.
    private var focusedIndex: Int {
        min(max(Int(position.rounded()), 0), placards.count)
    }

    private var isOnNewCard: Bool { focusedIndex == placards.count }

    private var focusedPlacard: Placard? {
        isOnNewCard ? nil : placards[focusedIndex]
    }

    /// The centred placard is already on the widget, so dragging it into the
    /// slot again would do nothing; the slot locks instead.
    private var isFocusedEquipped: Bool {
        focusedPlacard.map { equippedID == $0.id.uuidString } ?? false
    }

    private var isSettled: Bool {
        axis == nil && phase == .idle && verticalDrag == 0 &&
            abs(position - position.rounded()) < 0.001 && (gapAmount == 0)
    }

    private func distance(of index: Int) -> CGFloat {
        var d = CGFloat(index) - position
        if let gapIndex, index >= gapIndex { d += gapAmount }
        return d
    }

    private func downProgress(_ m: CarouselMetrics) -> CGFloat { max(0, verticalDrag) / m.equipThreshold }
    private func upProgress(_ m: CarouselMetrics) -> CGFloat {
        if case .deleting = phase { return 1 }
        return max(0, -verticalDrag) / m.deleteThreshold
    }

    // MARK: - Stage

    @ViewBuilder private func ambientGlow(_ m: CarouselMetrics) -> some View {
        if let placard = focusedPlacard {
            SignRenderer(sign: placard.sign, cornerRadius: 40)
                .frame(width: m.cardWidth * 1.5, height: m.cardHeight * 1.5)
                .blur(radius: 70)
                .saturation(1.5)
                .opacity(0.32)
                .position(x: m.size.width / 2, y: m.centerY)
                .id(placard.id)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.6), value: placard.id)
                .allowsHitTesting(false)
        }
    }

    private func stage(_ m: CarouselMetrics) -> some View {
        let pd = downProgress(m)
        let pu = upProgress(m)

        return ZStack {
            // Resting frame the centered card sits in; it turns gold when the
            // card is settled and stays as an empty outline while it is dragged.
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(
                    isSettled ? AnyShapeStyle(.widyip) : AnyShapeStyle(.white.opacity(0.16)),
                    lineWidth: isSettled ? 2 : 1
                )
                .shadow(color: .widyipPink.opacity(isSettled ? 0.55 : 0), radius: 14)
                .frame(width: m.cardWidth + 16, height: m.cardHeight + 16)
                .position(x: m.size.width / 2, y: m.centerY)
                .animation(.easeOut(duration: 0.25), value: isSettled)

            TrashTarget(progress: pu, armed: armed == .delete || isDeletingPhase)
                .position(x: m.size.width / 2, y: m.centerY + m.trashOffset)

            DragChevron(systemName: "chevron.compact.up", bobs: -1)
                .position(x: m.size.width / 2, y: m.centerY - m.cardHeight / 2 - 30)
                .opacity(isSettled && !isOnNewCard ? 0.4 : 0)
            DragChevron(systemName: "chevron.compact.down", bobs: 1)
                .position(x: m.size.width / 2, y: m.centerY + m.cardHeight / 2 + 30)
                .opacity(isSettled && !isFocusedEquipped && !isOnNewCard ? 0.55 : 0)

            ForEach(Array(placards.enumerated()), id: \.element.id) { index, placard in
                if abs(distance(of: index)) < 2.6 {
                    card(placard, index: index, metrics: m)
                }
            }

            if abs(distance(of: placards.count)) < 2.6 {
                newPlacardCard(metrics: m)
            }

            // Drawn above the cards so a card sinking into it disappears under its lip.
            EquipSlot(
                width: m.cardWidth * 0.84,
                progress: min(1.2, pd),
                armed: armed == .equip,
                flash: slotFlash,
                isLocked: (isFocusedEquipped || isOnNewCard) && phase == .idle
            )
            .position(x: m.size.width / 2, y: m.centerY + m.slotOffset)
            .allowsHitTesting(false)

            if isCoaching {
                coachOverlay(m)
                    .zIndex(30)
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(carouselGesture(m))
    }

    private var isDeletingPhase: Bool {
        if case .deleting = phase { return true }
        return false
    }

    private func card(_ placard: Placard, index: Int, metrics m: CarouselMetrics) -> some View {
        let pose = pose(for: placard.id, index: index, metrics: m)
        let isDeleting = phase == .deleting(placard.id)
        // Height of the card (in its own frame) that is still above the slot lip.
        let visibleHeight = m.slotLine - pose.y + m.cardHeight / 2

        return CarouselPlacardCard(
            placard: placard,
            glare: tilt.x * 0.9 - distance(of: index) * 0.9,
            redTint: pose.redTint
        )
        .frame(width: m.cardWidth, height: m.cardHeight)
        .overlay {
            if isDeleting {
                PlacardDissolveParticles(progress: dissolve)
                    .allowsHitTesting(false)
            }
        }
        .opacity(isDeleting ? max(0, 1 - dissolve * 1.2) : 1)
        .blur(radius: isDeleting ? dissolve * 3 : 0)
        .scaleEffect(pose.scale)
        .rotation3DEffect(.degrees(pose.yaw), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
        .rotation3DEffect(.degrees(pose.pitch), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.55)
        .rotationEffect(.degrees(pose.roll))
        .mask(alignment: .top) {
            Rectangle()
                .frame(width: m.cardWidth * 2, height: max(0, visibleHeight) + 400)
                .offset(y: -400)
        }
        .opacity(pose.opacity)
        .position(x: m.size.width / 2 + pose.x, y: m.centerY + pose.y)
        .zIndex(pose.zIndex)
        .onTapGesture {
            guard phase == .idle else { return }
            if isCoaching { endCoaching() }
            if index == focusedIndex {
                editingPlacard = placard
            } else {
                withAnimation(.spring(response: 0.46, dampingFraction: 0.84)) {
                    position = CGFloat(index)
                }
            }
        }
        .contextMenu {
            Button { editingPlacard = placard } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button { focusThen(index) { equip(placard) } } label: {
                Label("Equip widget", systemImage: "rectangle.on.rectangle")
            }
            .disabled(equippedID == placard.id.uuidString)
            Button(role: .destructive) { focusThen(index) { delete(placard) } } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(placard.title)
        .accessibilityAddTraits(index == focusedIndex ? .isSelected : [])
        .accessibilityAction(named: "Edit") { editingPlacard = placard }
        .accessibilityAction(named: "Equip widget") { focusThen(index) { equip(placard) } }
        .accessibilityAction(named: "Delete") { focusThen(index) { delete(placard) } }
    }

    private func newPlacardCard(metrics m: CarouselMetrics) -> some View {
        let index = placards.count
        let pose = pose(for: nil, index: index, metrics: m)
        return NewPlacardCard()
            .frame(width: m.cardWidth, height: m.cardHeight)
            .scaleEffect(pose.scale)
            .rotation3DEffect(.degrees(pose.yaw), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
            .opacity(pose.opacity)
            .position(x: m.size.width / 2 + pose.x, y: m.centerY + pose.y)
            .zIndex(pose.zIndex)
            .onTapGesture {
                guard phase == .idle else { return }
                if index == focusedIndex {
                    isChoosingTemplate = true
                } else {
                    withAnimation(.spring(response: 0.46, dampingFraction: 0.84)) {
                        position = CGFloat(index)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("New placard")
            .accessibilityAddTraits(.isButton)
    }

    /// `id` is nil for the "new placard" card, which never equips or deletes.
    private func pose(for id: UUID?, index: Int, metrics m: CarouselMetrics) -> CardPose {
        let d = distance(of: index)
        let ad = abs(d)
        var pose = CardPose()

        // Neighbors bunch up past the first stop so only a sliver of the second shows.
        pose.x = ad <= 1 ? d * m.spacing : (d < 0 ? -1 : 1) * (m.spacing + (ad - 1) * m.spacing * 0.42)
        pose.scale = 1 - min(ad, 2) * 0.15
        pose.yaw = min(55, max(-55, -d * 34))
        pose.opacity = max(0, 1 - max(0, ad - 0.9) * 0.85)
        pose.zIndex = 10 - Double(ad)

        let pd = downProgress(m)
        let pu = upProgress(m)

        switch phase {
        case .equipping(let target) where target == id, .equipped(let target) where target == id:
            pose.y = m.slotLine + m.cardHeight * 0.95
            pose.scale = 0.86
            pose.pitch = 22
            return pose
        case .deleting(let target) where target == id:
            pose.y = m.trashOffset
            pose.scale = 0.3
            pose.roll = -10
            pose.zIndex = 20
            return pose
        default:
            break
        }

        if index == focusedIndex && phase == .idle && id != nil {
            pose.y = verticalDrag
            pose.scale *= 1 - 0.13 * min(pd, 1.4) - 0.2 * min(pu, 1.3)
            pose.pitch = 16 * min(pd, 1.3)
            pose.roll = -5 * min(pu, 1.3)
            pose.yaw += tilt.x * 7
            pose.redTint = armed == .delete ? 0.34 : min(pu, 1) * 0.12
            pose.zIndex = 15
        } else {
            pose.opacity *= 1 - 0.75 * min(1, max(pd, pu))
        }
        return pose
    }

    // MARK: - Coach

    private func coachOverlay(_ m: CarouselMetrics) -> some View {
        ZStack {
            GhostFinger(pressed: coachPressed)
                .opacity(coachFingerVisible ? 1 : 0)
                .position(x: m.size.width / 2 + coachFinger.x, y: m.centerY + coachFinger.y)

            Label(coachStep.title, systemImage: coachStep.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 38)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(.widyip, lineWidth: 1) }
                .id(coachStep)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
                .position(x: m.size.width / 2, y: m.centerY - m.cardHeight / 2 - 64)
        }
        .allowsHitTesting(false)
        .task { await runCoach(m) }
    }

    private func runCoach(_ m: CarouselMetrics) async {
        func wait(_ s: Double) async -> Bool {
            (try? await Task.sleep(for: .seconds(s))) != nil && isCoaching
        }
        guard await wait(0.8) else { return }
        while isCoaching {
            // Tap to edit.
            withAnimation(.smooth(duration: 0.35)) { coachStep = .tap }
            coachFinger = CGPoint(x: 30, y: 40)
            withAnimation(.easeOut(duration: 0.35)) {
                coachFingerVisible = true
                coachFinger = CGPoint(x: 30, y: 10)
            }
            for _ in 0..<2 {
                guard await wait(0.55) else { return }
                withAnimation(.easeOut(duration: 0.1)) { coachPressed = true }
                guard await wait(0.14) else { return }
                withAnimation(.easeOut(duration: 0.16)) { coachPressed = false }
            }
            guard await wait(0.9) else { return }

            // Drag down to equip, nudging the real card toward the slot.
            withAnimation(.smooth(duration: 0.35)) { coachStep = .drag }
            guard await wait(0.4) else { return }
            withAnimation(.easeOut(duration: 0.1)) { coachPressed = true }
            guard await wait(0.15) else { return }
            withAnimation(.easeInOut(duration: 0.8)) {
                coachFinger.y += m.equipThreshold * 0.55
                verticalDrag = m.equipThreshold * 0.55
            }
            guard await wait(0.9) else { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.65)) {
                verticalDrag = 0
                coachPressed = false
                coachFingerVisible = false
            }
            guard await wait(1.2) else { return }
        }
    }

    private func endCoaching() {
        withAnimation(.easeOut(duration: 0.25)) {
            isCoaching = false
            coachFingerVisible = false
            coachPressed = false
            verticalDrag = 0
        }
    }

    // MARK: - Gesture

    private func carouselGesture(_ m: CarouselMetrics) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard phase == .idle, editingPlacard == nil, !placards.isEmpty else { return }
                if isCoaching { endCoaching() }

                if axis == nil {
                    let horizontal = abs(value.translation.width) > abs(value.translation.height)
                    axis = horizontal ? .horizontal : .vertical
                    dragStartPosition = position
                    if !horizontal, position != position.rounded() {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                            position = position.rounded()
                        }
                    }
                }

                switch axis {
                case .horizontal:
                    let raw = dragStartPosition - value.translation.width / m.spacing
                    let upper = CGFloat(placards.count)
                    if raw < 0 {
                        position = -Self.rubberBand(-raw, limit: 0)
                    } else if raw > upper {
                        position = upper + Self.rubberBand(raw - upper, limit: 0)
                    } else {
                        position = raw
                    }
                case .vertical:
                    // The "new placard" card has nothing to equip or delete.
                    guard !isOnNewCard else { return }
                    let raw = value.translation.height
                    if raw >= 0 && isFocusedEquipped {
                        // Locked: the card only gives a little, like pushing against a stop.
                        verticalDrag = Self.rubberBand(raw, limit: 0) * 0.5
                    } else {
                        verticalDrag = raw >= 0
                            ? Self.rubberBand(raw, limit: m.equipThreshold + 24)
                            : -Self.rubberBand(-raw, limit: m.deleteThreshold + 24)
                    }
                    let zone: DropZone? = verticalDrag >= m.equipThreshold && !isFocusedEquipped ? .equip
                        : verticalDrag <= -m.deleteThreshold ? .delete : nil
                    if zone != armed {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) { armed = zone }
                    }
                case nil:
                    break
                }
            }
            .onEnded { value in
                defer { axis = nil }
                guard phase == .idle, !placards.isEmpty else { return }

                switch axis {
                case .horizontal:
                    let current = dragStartPosition.rounded()
                    let predicted = dragStartPosition - value.predictedEndTranslation.width / m.spacing
                    let target = min(max(predicted.rounded(), current - 2, 0), current + 2, CGFloat(placards.count))
                    withAnimation(.spring(response: 0.46, dampingFraction: 0.84)) {
                        position = target
                    }
                case .vertical:
                    guard let placard = focusedPlacard else { break }
                    let flick = value.predictedEndTranslation.height
                    if !isFocusedEquipped,
                       armed == .equip || (verticalDrag > m.equipThreshold * 0.45 && flick > m.equipThreshold * 1.6) {
                        equip(placard)
                    } else if armed == .delete || (verticalDrag < -m.deleteThreshold * 0.5 && flick < -m.deleteThreshold * 1.8) {
                        delete(placard)
                    } else {
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.62)) {
                            verticalDrag = 0
                            armed = nil
                        }
                    }
                case nil:
                    break
                }
            }
    }

    private static func rubberBand(_ value: CGFloat, limit: CGFloat) -> CGFloat {
        guard value > limit else { return value }
        return limit + (value - limit) * 0.32
    }

    // MARK: - Actions

    private func focusThen(_ index: Int, _ action: @escaping () -> Void) {
        guard index != focusedIndex else { return action() }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { position = CGFloat(index) }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(380))
            action()
        }
    }

    private func equip(_ placard: Placard) {
        guard phase == .idle, equippedID != placard.id.uuidString else { return }
        withAnimation(.easeIn(duration: 0.24)) {
            phase = .equipping(placard.id)
            verticalDrag = 0
            armed = nil
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            SignStore.save(placard.sign)
            WidgetCenter.shared.reloadAllTimelines()
            equippedID = placard.id.uuidString
            equipCount += 1

            withAnimation(.easeOut(duration: 0.12)) { slotFlash = 1 }
            try? await Task.sleep(for: .milliseconds(130))
            withAnimation(.easeOut(duration: 0.8)) { slotFlash = 0 }
            try? await Task.sleep(for: .milliseconds(160))

            phase = .equipped(placard.id)
            withAnimation(.easeOut(duration: 0.3)) { reveal = placard }
        }
    }

    private func finishReveal() {
        // The card rises back out of the slot as the reveal fades away.
        withAnimation(.spring(response: 0.62, dampingFraction: 0.74)) {
            reveal = nil
            phase = .idle
        }
    }

    private func delete(_ placard: Placard) {
        guard phase == .idle, let index = placards.firstIndex(where: { $0.id == placard.id }) else { return }
        withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
            phase = .deleting(placard.id)
            verticalDrag = 0
            armed = nil
        }
        deleteCount += 1

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            withAnimation(.easeOut(duration: 0.45)) { dissolve = 1 }
            try? await Task.sleep(for: .milliseconds(470))

            let wasEquipped = equippedID == placard.id.uuidString
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                placards.remove(at: index)
                phase = .idle
                dissolve = 0
                if index < placards.count {
                    // Keep the next card visually where it was, then slide it in.
                    gapIndex = index
                    gapAmount = 1
                }
            }
            if wasEquipped { equippedID = "" }

            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                if index < placards.count {
                    gapAmount = 0
                } else {
                    position = CGFloat(max(0, placards.count - 1))
                }
                pendingUndo = DeletedPlacard(placard: placard, index: index, wasEquipped: wasEquipped)
            }
        }
    }

    private func undoDelete() {
        guard let undo = pendingUndo, phase == .idle else { return }
        let index = min(undo.index, placards.count)

        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            placards.insert(undo.placard, at: index)
            // Hold everything after the restored card in place, and start the
            // restored card dissolved inside the bin so it reassembles on the way out.
            gapIndex = index + 1
            gapAmount = -1
            phase = .deleting(undo.placard.id)
            dissolve = 1
        }
        if undo.wasEquipped { equippedID = undo.placard.id.uuidString }

        withAnimation(.spring(response: 0.56, dampingFraction: 0.8)) {
            position = CGFloat(index)
            gapAmount = 0
            phase = .idle
            dissolve = 0
            pendingUndo = nil
        }
    }

    private func binding(for id: UUID) -> Binding<Placard> {
        Binding(
            get: { placards.first(where: { $0.id == id }) ?? Placard(sign: .fallback) },
            set: { updated in
                guard let index = placards.firstIndex(where: { $0.id == id }) else { return }
                placards[index] = updated
                if equippedID == id.uuidString {
                    SignStore.save(updated.sign)
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }
        )
    }

    // MARK: - Chrome

    private func chrome(_ m: CarouselMetrics) -> some View {
        let pu = placards.isEmpty ? 0 : upProgress(m)

        return ZStack {
            Image("WidyipHeader")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 230)
                .padding(.top, 18)
                .frame(maxHeight: .infinity, alignment: .top)
                .opacity(1 - min(1, pu * 1.8))
                .allowsHitTesting(false)


            if !placards.isEmpty {
                hintLabel
                    .position(x: m.size.width / 2, y: m.centerY + m.slotOffset + 46)

                PageDots(count: placards.count + 1, index: focusedIndex, endsWithAdd: true)
                    .position(x: m.size.width / 2, y: m.centerY + m.slotOffset + 82)
            }

            if let undo = pendingUndo {
                UndoToast(wasEquipped: undo.wasEquipped, undo: undoDelete)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var hintLabel: some View {
        let (text, style): (String, AnyShapeStyle) = {
            switch armed {
            case .equip: return ("Release to equip widget", AnyShapeStyle(.widyip))
            case .delete: return ("Release to delete", AnyShapeStyle(Color.widyipRed))
            case nil:
                if isOnNewCard { return ("Tap to make a new placard", AnyShapeStyle(.white.opacity(0.42))) }
                if verticalDrag < -4 { return ("Drag up to delete", AnyShapeStyle(.white.opacity(0.6))) }
                if isFocusedEquipped { return ("On your widget", AnyShapeStyle(.widyip)) }
                return ("Drag down to equip widget", AnyShapeStyle(.white.opacity(0.42)))
            }
        }()

        return Text(text)
            .font(.footnote.weight(armed == nil ? .medium : .bold))
            .foregroundStyle(style)
            .contentTransition(.interpolate)
            .animation(.easeOut(duration: 0.2), value: text)
            .allowsHitTesting(false)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No placards yet", systemImage: "rectangle.on.rectangle")
        } description: {
            Text("Choose a template to make your first placard.")
        } actions: {
            Button("Choose a template") { isChoosingTemplate = true }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 18)
                .frame(height: 42)
                .background(.widyip, in: Capsule())
                .buttonStyle(.plain)
        }
    }
}

// MARK: - Carousel model

private enum DragAxis { case horizontal, vertical }

private enum CoachStep {
    case tap, drag
    var title: String { self == .tap ? "Tap to edit" : "Drag down to equip your widget" }
    var symbol: String { self == .tap ? "hand.tap" : "arrow.down" }
}

private enum DropZone: Equatable { case equip, delete }

private enum CommitPhase: Equatable {
    case idle
    case equipping(UUID)
    case equipped(UUID)
    case deleting(UUID)
}

private struct DeletedPlacard: Equatable {
    let placard: Placard
    let index: Int
    let wasEquipped: Bool
}

private struct CardPose {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var scale: CGFloat = 1
    var opacity: CGFloat = 1
    var yaw: CGFloat = 0
    var pitch: CGFloat = 0
    var roll: CGFloat = 0
    var redTint: CGFloat = 0
    var zIndex: Double = 0
}

private struct CarouselMetrics {
    let size: CGSize

    var cardWidth: CGFloat { min(size.width - 92, 330) }
    var cardHeight: CGFloat { cardWidth / 2 }
    var spacing: CGFloat { cardWidth * 0.86 }
    var centerY: CGFloat { size.height * 0.4 }
    /// Card center to the equip slot.
    var slotOffset: CGFloat { cardHeight / 2 + min(150, size.height * 0.19) }
    /// Card center to the slot lip, below which a sinking card is hidden.
    var slotLine: CGFloat { slotOffset - 6 }
    var equipThreshold: CGFloat { slotOffset - cardHeight * 0.35 }
    /// Card center to the delete bin (negative: above).
    var trashOffset: CGFloat { -(cardHeight / 2 + min(118, size.height * 0.14)) }
    var deleteThreshold: CGFloat { abs(trashOffset) - 34 }
}

extension ShapeStyle where Self == LinearGradient {
    /// The app's accent: the logo's lime fading into its pink.
    static var widyip: LinearGradient {
        LinearGradient(colors: [.widyipLime, .widyipPink], startPoint: .leading, endPoint: .trailing)
    }
}

extension Color {
    /// Near-black base for every screen: deep, but not a flat void, so glass
    /// has something to refract.
    static let widyipBackground = Color(red: 10 / 255, green: 10 / 255, blue: 13 / 255)

    /// The two colours of the WIDYIP logo.
    static let widyipLime = Color(red: 0x9F / 255, green: 1, blue: 0x1F / 255)
    static let widyipPink = Color(red: 1, green: 0x66 / 255, blue: 0xC5 / 255)
    static let widyipRed = Color(red: 1, green: 0.27, blue: 0.27)
}

// MARK: - Carousel pieces

private struct CarouselPlacardCard: View {
    let placard: Placard
    let glare: CGFloat
    let redTint: CGFloat

    private let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

    var body: some View {
        SignRenderer(sign: placard.sign, cornerRadius: 18)
            .overlay {
                // A soft specular band that tracks device tilt and swipe distance.
                GeometryReader { proxy in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.16), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: proxy.size.width * 0.5, height: proxy.size.height * 2)
                    .rotationEffect(.degrees(18))
                    .offset(x: proxy.size.width * (0.25 + glare * 0.55), y: -proxy.size.height * 0.5)
                    .blendMode(.plusLighter)
                }
                .clipShape(shape)
                .allowsHitTesting(false)
            }
            .overlay { shape.fill(Color.widyipRed.opacity(redTint)) }
            .overlay { shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.6) }
            .shadow(color: .black.opacity(0.6), radius: 18, y: 14)
    }
}

/// The deck's last stop: a dashed placard-sized card that starts a new placard.
private struct NewPlacardCard: View {
    private let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

    var body: some View {
        ZStack {
            shape.fill(.white.opacity(0.04))
            shape.strokeBorder(.white.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
            VStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 48, height: 48)
                    .background(.widyip, in: Circle())
                    .shadow(color: .widyipPink.opacity(0.4), radius: 12)
                Text("New placard")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }
}

private struct EquipSlot: View {
    let width: CGFloat
    let progress: CGFloat
    let armed: Bool
    let flash: CGFloat
    var isLocked = false

    var body: some View {
        ZStack {
            Ellipse()
                .fill(.widyip)
                .frame(width: width * 0.95, height: 54)
                .blur(radius: 30)
                .phaseAnimator([0.16, 0.3]) { glow, value in
                    glow.opacity(isLocked ? 0.06 : value + 0.45 * progress + 0.7 * flash)
                } animation: { _ in .easeInOut(duration: 1.6) }

            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(white: 0.02), Color(white: 0.13)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .frame(width: width, height: 18)
                .overlay(alignment: .top) {
                    Capsule()
                        .fill(LinearGradient(
                            colors: [.clear, .widyipLime, .widyipPink, .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .frame(height: armed ? 3 : 2)
                        .opacity(isLocked ? 0.25 : 0.55 + 0.45 * min(1, progress) + flash)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 0.6)
                }
        }
        .scaleEffect(x: armed ? 1.06 : 1, y: 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: armed)
        .animation(.easeOut(duration: 0.3), value: isLocked)
    }
}

private struct TrashTarget: View {
    let progress: CGFloat
    let armed: Bool

    var body: some View {
        let p = min(1, progress)
        ZStack {
            Circle()
                .fill(Color.widyipRed)
                .frame(width: 96, height: 96)
                .blur(radius: 26)
                .opacity(0.12 + 0.4 * p + (armed ? 0.2 : 0))

            Circle()
                .fill(armed ? Color.widyipRed : .white.opacity(0.08))
                .frame(width: 58, height: 58)
                .overlay { Circle().strokeBorder(Color.widyipRed.opacity(0.6), lineWidth: 1) }

            Image(systemName: armed ? "trash.fill" : "trash")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(armed ? .white : Color.widyipRed)
                .symbolEffect(.bounce, value: armed)
        }
        .scaleEffect(0.6 + 0.4 * p + (armed ? 0.12 : 0))
        .opacity(min(1, p * 1.6))
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: armed)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct DragChevron: View {
    let systemName: String
    let bobs: CGFloat

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.white)
            .phaseAnimator([0, 1]) { chevron, phase in
                chevron.offset(y: phase * 3 * bobs)
            } animation: { _ in .easeInOut(duration: 0.9) }
            .animation(.easeOut(duration: 0.2), value: systemName)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct PageDots: View {
    let count: Int
    let index: Int
    /// The last stop is the "new placard" card, shown as a small plus.
    var endsWithAdd = false

    var body: some View {
        Group {
            if count > 12 {
                Text(endsWithAdd && index == count - 1 ? "New" : "\(index + 1) / \(endsWithAdd ? count - 1 : count)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
            } else if count > 1 {
                HStack(spacing: 5) {
                    ForEach(0..<count, id: \.self) { dot in
                        if endsWithAdd && dot == count - 1 {
                            Image(systemName: "plus")
                                .font(.system(size: 7, weight: .heavy))
                                .foregroundStyle(dot == index ? Color.white.opacity(0.85) : .white.opacity(0.3))
                                .frame(width: 9, height: 9)
                        } else {
                            Capsule()
                                .fill(dot == index ? Color.white.opacity(0.85) : .white.opacity(0.22))
                                .frame(width: dot == index ? 16 : 5, height: 5)
                        }
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: index)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct UndoToast: View {
    let wasEquipped: Bool
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.widyipRed)
            VStack(alignment: .leading, spacing: 1) {
                Text("Placard deleted")
                    .font(.subheadline.weight(.semibold))
                if wasEquipped {
                    Text("Your widget keeps showing it until you equip another.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button("Undo", action: undo)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.widyip)
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .libraryGlassRoundedRect()
    }
}

// MARK: - Equip reveal

private struct EquipRevealView: View {
    let placard: Placard
    let done: () -> Void

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.62))
                .background(.ultraThinMaterial)
                .ignoresSafeArea()

            if !reduceMotion {
                ConfettiBurst()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                Spacer()

                Label("Equipped", systemImage: "checkmark.seal.fill")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(.widyip, in: Capsule())
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 10)
                    .padding(.bottom, 26)

                SignRenderer(sign: placard.sign, cornerRadius: 22)
                    .aspectRatio(2, contentMode: .fit)
                    .frame(maxWidth: 330)
                    .shadow(color: .widyipPink.opacity(0.35), radius: 34)
                    .shadow(color: .black.opacity(0.6), radius: 20, y: 16)
                    .scaleEffect(appeared ? 1 : 0.55)
                    .rotation3DEffect(.degrees(appeared ? 0 : 68), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
                    .offset(y: appeared ? 0 : 240)
                    .opacity(appeared ? 1 : 0)

                VStack(spacing: 8) {
                    Text("Nasa widget mo na!")
                        .font(.title2.weight(.bold))
                    Text("Your Widyip widget now shows this placard.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .padding(.top, 34)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 14)
                .animation(.easeOut(duration: 0.5).delay(0.18), value: appeared)

                Spacer()

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "plus.square.on.square")
                        .foregroundStyle(.widyip)
                    Text("No widget yet? Long-press your Home Screen, tap Edit, then Add Widget and search Widyip.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .opacity(appeared ? 1 : 0)
                .animation(.easeOut(duration: 0.5).delay(0.32), value: appeared)

                Button(action: done) {
                    Text("Done")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(.widyip, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 14)
                .opacity(appeared ? 1 : 0)
                .animation(.easeOut(duration: 0.5).delay(0.4), value: appeared)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
            .foregroundStyle(.white)
        }
        .onAppear {
            withAnimation(.spring(response: 0.62, dampingFraction: 0.66).delay(0.04)) {
                appeared = true
            }
        }
    }
}

private struct ConfettiBurst: View {
    @State private var start = Date()

    private static let colors: [Color] = [
        .widyipLime, .widyipPink, .widyipRed, .white,
        Color(red: 0.62, green: 1, blue: 0.2),
        Color(red: 1, green: 0.4, blue: 0.75),
        Color(red: 0.3, green: 0.85, blue: 1)
    ]

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            Canvas { context, size in
                guard t < 3.4 else { return }
                let origin = CGPoint(x: size.width / 2, y: size.height * 0.42)

                for index in 0..<110 {
                    let seed = Double((index &* 7919) % 1000) / 1000
                    let seed2 = Double((index &* 104_729) % 1000) / 1000
                    let angle = -Double.pi / 2 + (seed - 0.5) * 2.6
                    let speed = 380 + seed2 * 620
                    let delay = seed2 * 0.12
                    let local = max(0, t - delay)
                    guard local > 0 else { continue }

                    // Ballistic burst with drag so pieces hang before they fall.
                    let drag = 1 - exp(-2.6 * local)
                    let x = origin.x + cos(angle) * speed * drag / 2.6
                    let y = origin.y + sin(angle) * speed * drag / 2.6 + 240 * local * local
                    let fade = max(0, min(1, (3.2 - local) / 0.8))

                    var piece = context
                    piece.translateBy(x: x, y: y)
                    piece.rotate(by: .radians(local * (4 + seed * 8) * (index.isMultiple(of: 2) ? 1 : -1)))
                    piece.scaleBy(x: cos(local * (6 + seed2 * 6)), y: 1)
                    let w = 6 + seed * 6
                    let h = 3 + seed2 * 4
                    piece.fill(
                        Path(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), cornerRadius: 1),
                        with: .color(Self.colors[index % Self.colors.count].opacity(fade))
                    )
                }
            }
        }
    }
}

private extension View {
    @ViewBuilder func libraryGlassRoundedRect() -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay { shape.stroke(.white.opacity(0.2), lineWidth: 0.8) }
        }
    }
}

private struct PlacardDissolveParticles: View {
    let progress: CGFloat

    var body: some View {
        Canvas { context, size in
            for index in 0..<84 {
                let seed = index &* 37 &+ 19
                let delay = CGFloat(seed % 38) / 100
                let local = min(1, max(0, (progress - delay) / max(0.01, 1 - delay)))
                guard local > 0 else { continue }

                let column = CGFloat(index % 12)
                let row = CGFloat(index / 12)
                let baseX = (column + 0.5) / 12 * size.width
                let baseY = (row + 0.5) / 7 * size.height
                let driftX = CGFloat((seed % 15) - 7) * size.width * 0.012 * local
                let driftY = -size.height * (0.06 + CGFloat(seed % 11) * 0.008) * local
                let shard = 2.5 + CGFloat(seed % 5)
                let opacity = (1 - local) * 0.9
                let palette: [Color] = [.white, .gray, .yellow, .black]
                let color = palette[seed % palette.count].opacity(opacity)
                let rect = CGRect(
                    x: baseX + driftX - shard / 2,
                    y: baseY + driftY - shard / 2,
                    width: shard,
                    height: shard * (0.7 + CGFloat(seed % 3) * 0.2)
                )
                context.fill(Path(roundedRect: rect, cornerRadius: 0.8), with: .color(color))
            }
        }
    }
}

private struct PhysicsHangingPlacard: View {
    let placard: Placard
    let index: Int
    let impulse: Double
    let pulse: Int
    let tiltX: Double
    let tiltY: Double
    let deviceKick: DeviceMotionKick
    let devicePulse: Int

    @State private var angle: Double = 0
    @State private var angularVelocity: Double = 0
    @State private var pitchAngle: Double = 0
    @State private var pitchVelocity: Double = 0
    @State private var yawAngle: Double = 0
    @State private var yawVelocity: Double = 0
    @State private var simulationTask: Task<Void, Never>?

    private var direction: Double { index.isMultiple(of: 2) ? 1 : -1 }
    private var responsiveness: Double { [3.7, 3.1, 4.2, 3.4][index % 4] }
    private var stiffness: Double { [17.5, 14.8, 19.2, 16.1][index % 4] }
    private var damping: Double { [1.18, 1.02, 1.3, 1.1][index % 4] }
    private var depth: Double { [1.0, 0.82, 1.12, 0.92][index % 4] }

    var body: some View {
        HangingPlacard(
            placard: placard,
            roll: angle * 0.34 + tiltX * 3.2 * depth,
            pitch: pitchAngle + tiltY * 8.5 * depth,
            yaw: yawAngle + tiltX * 2.4 * depth
        )
            .onChange(of: pulse) { _, _ in applyScrollImpulse() }
            .onChange(of: devicePulse) { _, _ in applyDeviceImpulse() }
            .onDisappear {
                simulationTask?.cancel()
                simulationTask = nil
            }
    }

    private func applyScrollImpulse() {
        angularVelocity = min(88, max(-88,
            angularVelocity * 0.64 + impulse * responsiveness * direction * 0.2
        ))
        pitchVelocity = min(82, max(-82,
            pitchVelocity * 0.68 + impulse * responsiveness * 1.15
        ))
        yawVelocity = min(62, max(-62,
            yawVelocity * 0.66 + impulse * responsiveness * direction * 0.2
        ))
        startSimulationIfNeeded()
    }

    private func applyDeviceImpulse() {
        let variedDirection = direction * depth
        let shakeBoost = deviceKick.intensity > 0.45
            ? min(2.8, 1 + deviceKick.intensity * 1.4)
            : 1
        angularVelocity = min(72, max(-72,
            angularVelocity * 0.7 +
            (deviceKick.accelerationX * 12 * variedDirection + deviceKick.accelerationY * 18 * direction + deviceKick.rotationZ * 1.8 * depth) * shakeBoost
        ))
        pitchVelocity = min(82, max(-82,
            pitchVelocity * 0.76 +
            (-deviceKick.accelerationZ * 82 * depth + deviceKick.accelerationY * 48 * depth + deviceKick.rotationX * 6.5 * variedDirection) * shakeBoost
        ))
        yawVelocity = min(62, max(-62,
            yawVelocity * 0.74 +
            (deviceKick.accelerationX * 28 * depth + deviceKick.accelerationY * 12 * variedDirection + deviceKick.rotationY * 4.8 * variedDirection) * shakeBoost
        ))
        startSimulationIfNeeded()
    }

    private func startSimulationIfNeeded() {
        guard simulationTask == nil else { return }

        simulationTask = Task { @MainActor in
            let timeStep = 1.0 / 60.0

            while !Task.isCancelled {
                let acceleration = -stiffness * angle - damping * angularVelocity
                angularVelocity += acceleration * timeStep
                angle += angularVelocity * timeStep
                if abs(angle) > 2.1 {
                    angle = angle.sign == .minus ? -2.1 : 2.1
                    angularVelocity *= -0.22
                }

                let pitchAcceleration = -(stiffness * 1.18) * pitchAngle - (damping * 1.08) * pitchVelocity
                pitchVelocity += pitchAcceleration * timeStep
                pitchAngle += pitchVelocity * timeStep
                if abs(pitchAngle) > 15 {
                    pitchAngle = pitchAngle.sign == .minus ? -15 : 15
                    pitchVelocity *= -0.2
                }

                let yawAcceleration = -(stiffness * 0.86) * yawAngle - (damping * 1.16) * yawVelocity
                yawVelocity += yawAcceleration * timeStep
                yawAngle += yawVelocity * timeStep
                if abs(yawAngle) > 6 {
                    yawAngle = yawAngle.sign == .minus ? -6 : 6
                    yawVelocity *= -0.2
                }

                if abs(angle) < 0.02 && abs(angularVelocity) < 0.08 &&
                    abs(pitchAngle) < 0.02 && abs(pitchVelocity) < 0.08 &&
                    abs(yawAngle) < 0.02 && abs(yawVelocity) < 0.08 {
                    angle = 0
                    angularVelocity = 0
                    pitchAngle = 0
                    pitchVelocity = 0
                    yawAngle = 0
                    yawVelocity = 0
                    break
                }

                try? await Task.sleep(nanoseconds: 16_666_667)
            }

            simulationTask = nil
        }
    }
}

struct DeviceMotionKick: Equatable {
    let accelerationX: Double
    let accelerationY: Double
    let accelerationZ: Double
    let intensity: Double
    let rotationX: Double
    let rotationY: Double
    let rotationZ: Double

    static let zero = DeviceMotionKick(
        accelerationX: 0,
        accelerationY: 0,
        accelerationZ: 0,
        intensity: 0,
        rotationX: 0,
        rotationY: 0,
        rotationZ: 0
    )
}

@MainActor
final class DeviceTiltObserver: ObservableObject {
    @Published private(set) var x: Double = 0
    @Published private(set) var y: Double = 0
    @Published private(set) var kick = DeviceMotionKick.zero
    @Published private(set) var kickPulse = 0

    private let motionManager = CMMotionManager()

    func start() {
        guard motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let gravity = motion.gravity
            x = x * 0.68 + gravity.x * 0.32
            // In portrait orientation, gravity Z tracks tilting the phone toward
            // and away from the user more directly than gravity Y.
            y = y * 0.68 + (-gravity.z) * 0.32

            let acceleration = motion.userAcceleration
            let rotation = motion.rotationRate
            let accelerationMagnitude = sqrt(
                acceleration.x * acceleration.x +
                acceleration.y * acceleration.y +
                acceleration.z * acceleration.z
            )
            let rotationMagnitude = sqrt(
                rotation.x * rotation.x +
                rotation.y * rotation.y +
                rotation.z * rotation.z
            )

            guard accelerationMagnitude > 0.025 || rotationMagnitude > 0.12 else { return }
            kick = DeviceMotionKick(
                accelerationX: min(1, max(-1, acceleration.x)),
                accelerationY: min(1, max(-1, acceleration.y)),
                accelerationZ: min(1, max(-1, acceleration.z)),
                intensity: min(2, accelerationMagnitude),
                rotationX: min(4, max(-4, rotation.x)),
                rotationY: min(4, max(-4, rotation.y)),
                rotationZ: min(4, max(-4, rotation.z))
            )
            kickPulse &+= 1
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
    }
}

struct HangingPlacard: View {
    let placard: Placard
    var roll: Double = 0
    var pitch: Double = 0
    var yaw: Double = 0
    var movement: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            PlacardMountAssembly(
                placard: placard,
                width: proxy.size.width,
                roll: roll,
                pitch: pitch,
                yaw: yaw,
                movement: movement
            )
        }
        .aspectRatio(1.34, contentMode: .fit)
    }
}

private struct PlacardMountAssembly: View {
    let placard: Placard
    let width: CGFloat
    let roll: Double
    let pitch: Double
    let yaw: Double
    let movement: CGSize

    private var signTop: CGFloat { width * 0.19 }
    private var signHeight: CGFloat { width * 0.5 }
    private var mountWidth: CGFloat { width * 0.92 }
    private var mountInset: CGFloat { (width - mountWidth) / 2 }
    private var mountDrop: CGFloat { width * 0.072 }
    private var attachmentLine: CGFloat { mountDrop + (mountWidth / 3) * 0.54 }
    private var attachmentAnchor: UnitPoint {
        UnitPoint(
            x: 0.5,
            y: min(1, max(0, (attachmentLine - signTop) / signHeight))
        )
    }

    // These fractions are shared by the mount artwork and the board, so the
    // recessed holes remain a part of the moving placard instead of the hook.
    // Derived from the visible silver hook centers in HookStemPair.png:
    // (422, 430) and (1750, 430) inside its 2172 x 724 source image.
    private let mountPositions: [CGFloat] = [0.2186, 0.7808]
    private let holeVerticalPosition: CGFloat = 0.128

    var body: some View {
        ZStack(alignment: .topLeading) {
            mountImage("SuctionPair", width: mountWidth, x: mountInset, y: mountDrop)

            ZStack {
                SignRenderer(sign: placard.sign, cornerRadius: 3)
                PlacardAttachmentHoles(
                    positions: mountPositions,
                    verticalPosition: holeVerticalPosition
                )
            }
                .frame(width: width, height: signHeight)
                .offset(y: signTop)
                .rotation3DEffect(
                    .degrees(pitch),
                    axis: (x: 1, y: 0, z: 0),
                    anchor: attachmentAnchor,
                    perspective: 0.65
                )
                .rotation3DEffect(
                    .degrees(yaw),
                    axis: (x: 0, y: 1, z: 0),
                    anchor: attachmentAnchor,
                    perspective: 0.65
                )
                .rotationEffect(.degrees(roll), anchor: attachmentAnchor)
                .offset(movement)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 5)

            mountImage("HookStemPair", width: mountWidth, x: mountInset, y: mountDrop)
                .shadow(color: .black.opacity(0.72), radius: width * 0.008, y: width * 0.012)
        }
    }

    private func mountImage(_ name: String, width: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Image(name)
            .resizable()
            .scaledToFit()
            .frame(width: width)
            .offset(x: x, y: y)
            .allowsHitTesting(false)
    }

}

private struct PlacardAttachmentHoles: View {
    let positions: [CGFloat]
    let verticalPosition: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let diameter = max(10, min(proxy.size.width * 0.045, proxy.size.height * 0.115))

            ForEach(positions, id: \.self) { position in
                ZStack {
                    Circle()
                        .fill(.black.opacity(0.38))
                        .blur(radius: diameter * 0.12)
                        .offset(y: diameter * 0.11)

                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    .black.opacity(0.98),
                                    .black.opacity(0.9),
                                    .black.opacity(0.62)
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: diameter * 0.5
                            )
                        )
                        .overlay(
                            Circle()
                                .stroke(.white.opacity(0.28), lineWidth: max(0.8, diameter * 0.055))
                                .blur(radius: 0.35)
                        )
                        .overlay(
                            Circle()
                                .stroke(.black.opacity(0.65), lineWidth: max(1, diameter * 0.11))
                                .padding(diameter * 0.055)
                        )
                }
                .frame(width: diameter, height: diameter)
                .position(
                    x: proxy.size.width * position,
                    y: proxy.size.height * verticalPosition
                )
            }
        }
        .allowsHitTesting(false)
    }
}

private struct LibraryScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

enum PlaceholderTemplate: CaseIterable, Identifiable {
    case blackDriver, whiteBarya, yellowBayad
    var id: Self { self }
    var title: String {
        switch self {
        case .blackDriver: "Basta Sweet Lover"
        case .whiteBarya: "Barya Lang"
        case .yellowBayad: "Bayad Muna"
        }
    }

    func makeSign() -> SignDraft {
        let red = SignColor(red: 1, green: 0.10, blue: 0.12)
        let black = SignColor(red: 0, green: 0, blue: 0)
        switch self {
        case .blackDriver:
            return SignDraft(layers: [
                TextLayer(text: "BASTA", font: .wide, fontFamily: .cubao, size: 116.0 / 288.0, x: 288.5 / 576.0, y: 63.0 / 288.0, color: .lime, gradientColor: .lime, width: 521.0 / 576.0, psdLayout: PSDTextLayout(x: 28.0 / 576.0, y: 26.0 / 288.0, width: 521.0 / 576.0, height: 74.0 / 288.0, horizontalScale: 1.5), psdRasterAsset: "BlackDriverBasta"),
                TextLayer(text: "SWEET  LOVER", font: .wide, fontFamily: .cubao, size: 78.0 / 288.0, x: 289.0 / 576.0, y: 141.5 / 288.0, color: .pink, gradientColor: .pink, width: 520.0 / 576.0, psdLayout: PSDTextLayout(x: 29.0 / 576.0, y: 116.0 / 288.0, width: 520.0 / 576.0, height: 51.0 / 288.0, horizontalScale: 1.45), psdRasterAsset: "BlackDriverSweetLover"),
                TextLayer(text: "DRIVER", font: .wide, fontFamily: .cubao, size: 116.0 / 288.0, x: 287.0 / 576.0, y: 224.5 / 288.0, rotation: 0.128, color: .lime, gradientColor: .lime, width: 520.0 / 576.0, psdLayout: PSDTextLayout(x: 27.0 / 576.0, y: 187.0 / 288.0, width: 520.0 / 576.0, height: 75.0 / 288.0, horizontalScale: 1.33), psdRasterAsset: "BlackDriverDriver")
            ], background: .blackDriver, psdReferenceAsset: "BlackDriverReference")
        case .whiteBarya:
            return SignDraft(layers: [
                TextLayer(text: "B", font: .regular, fontFamily: .kawit, size: 288.0 / 288.0, x: 70.5 / 576.0, y: 155.0 / 288.0, color: red, gradientColor: red, width: 133.0 / 576.0, psdLayout: PSDTextLayout(x: 4.0 / 576.0, y: 57.0 / 288.0, width: 133.0 / 576.0, height: 196.0 / 288.0), psdRasterAsset: "WhiteBaryaB"),
                TextLayer(text: "ARYA LAN", font: .regular, fontFamily: .kawit, size: 92.0 / 288.0, x: 285.0 / 576.0, y: 132.0 / 288.0, color: red, gradientColor: red, width: 314.0 / 576.0, psdLayout: PSDTextLayout(x: 128.0 / 576.0, y: 100.0 / 288.0, width: 314.0 / 576.0, height: 64.0 / 288.0), psdRasterAsset: "WhiteBaryaAryaLan"),
                TextLayer(text: "G", font: .regular, fontFamily: .kawit, size: 288.0 / 288.0, x: 498.5 / 576.0, y: 155.5 / 288.0, color: red, gradientColor: red, width: 143.0 / 576.0, psdLayout: PSDTextLayout(x: 427.0 / 576.0, y: 57.0 / 288.0, width: 143.0 / 576.0, height: 197.0 / 288.0), psdRasterAsset: "WhiteBaryaG"),
                TextLayer(text: "PO SA UMAGA", font: .wide, fontFamily: .cubao, size: 66.0 / 288.0, x: 286.0 / 576.0, y: 193.5 / 288.0, color: black, gradientColor: black, width: 284.0 / 576.0, psdLayout: PSDTextLayout(x: 144.0 / 576.0, y: 172.0 / 288.0, width: 284.0 / 576.0, height: 43.0 / 288.0), psdRasterAsset: "WhiteBaryaPoSaUmaga")
            ], background: .whiteBarya, psdReferenceAsset: "WhiteBaryaReference")
        case .yellowBayad:
            return SignDraft(layers: [
                TextLayer(text: "B", font: .regular, fontFamily: .quiapo, size: 170.0 / 288.0, x: 44.0 / 576.0, y: 136.5 / 288.0, rotation: -25.8, color: red, gradientColor: red, width: 76.0 / 576.0, psdLayout: PSDTextLayout(x: 6.0 / 576.0, y: 70.0 / 288.0, width: 76.0 / 576.0, height: 133.0 / 288.0), psdRasterAsset: "YellowBayadB"),
                TextLayer(text: "AYAD", font: .regular, fontFamily: .quiapo, size: 117.0 / 288.0, x: 182.5 / 576.0, y: 110.0 / 288.0, rotation: -13.85, color: red, gradientColor: red, width: 201.0 / 576.0, psdLayout: PSDTextLayout(x: 82.0 / 576.0, y: 42.0 / 288.0, width: 201.0 / 576.0, height: 136.0 / 288.0), psdRasterAsset: "YellowBayadAyad"),
                TextLayer(text: "MUN", font: .regular, fontFamily: .quiapo, size: 117.0 / 288.0, x: 405.5 / 576.0, y: 105.0 / 288.0, rotation: 15.37, color: red, gradientColor: red, width: 193.0 / 576.0, psdLayout: PSDTextLayout(x: 309.0 / 576.0, y: 43.0 / 288.0, width: 193.0 / 576.0, height: 124.0 / 288.0), psdRasterAsset: "YellowBayadMun"),
                TextLayer(text: "A", font: .regular, fontFamily: .quiapo, size: 170.0 / 288.0, x: 510.5 / 576.0, y: 130.0 / 288.0, rotation: 24.54, color: red, gradientColor: red, width: 97.0 / 576.0, psdLayout: PSDTextLayout(x: 462.0 / 576.0, y: 68.0 / 288.0, width: 97.0 / 576.0, height: 124.0 / 288.0), psdRasterAsset: "YellowBayadA"),
                TextLayer(text: "BAGO", font: .regular, fontFamily: .quiapo, size: 90.0 / 288.0, x: 203.0 / 576.0, y: 231.0 / 288.0, rotation: -11.17, color: black, gradientColor: black, width: 158.0 / 576.0, psdLayout: PSDTextLayout(x: 124.0 / 576.0, y: 183.0 / 288.0, width: 158.0 / 576.0, height: 96.0 / 288.0), psdRasterAsset: "YellowBayadBago"),
                TextLayer(text: "BABA", font: .regular, fontFamily: .quiapo, size: 90.0 / 288.0, x: 376.0 / 576.0, y: 230.5 / 288.0, rotation: 11.16, color: black, gradientColor: black, width: 152.0 / 576.0, psdLayout: PSDTextLayout(x: 300.0 / 576.0, y: 184.0 / 288.0, width: 152.0 / 576.0, height: 93.0 / 288.0), psdRasterAsset: "YellowBayadBaba")
            ], background: .yellowBayad, psdReferenceAsset: "YellowBayadReference")
        }
    }
}

private struct TemplatePicker: View {
    let choose: (SignDraft) -> Void
    @Environment(\.dismiss) private var dismiss

    /// Templates exported from the app and bundled with it come first. The
    /// built-in PSD templates follow, converted to live text so the picker shows
    /// exactly what the editor will.
    private var options: [(id: String, sign: SignDraft)] {
        let bundled = TemplateCatalog.bundled()
        let bundledNames = Set(bundled.map(\.name))
        let builtIn = PlaceholderTemplate.allCases
            .filter { !bundledNames.contains($0.title) }
            .map { (id: $0.title, sign: $0.makeSign().applyingImportedPSDLayout().bakingImportedPSDType()) }
        return bundled.map { (id: $0.name, sign: $0.makeSign()) } + builtIn
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(options, id: \.id) { option in
                        Button {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            choose(option.sign)
                        } label: {
                            SignRenderer(sign: option.sign)
                                .aspectRatio(2, contentMode: .fit)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.id)
                    }
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 8)
            }
            .navigationTitle("Choose a template")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .scrollContentBackground(.hidden)
            .background(Color.clear)
        }
        // No custom background: on iOS 26 the system draws the sheet in Liquid
        // Glass, but only below full height (a full-height sheet turns opaque).
        // This height fits all three templates without scrolling.
        .environment(\.colorScheme, .dark)
        .presentationDetents([.fraction(0.86)])
        .presentationDragIndicator(.visible)
    }
}
