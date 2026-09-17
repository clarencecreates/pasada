import SwiftUI

struct PlacardLibraryView: View {
    @State private var placards = PlacardStore.load()
    @State private var selectedPlacard: Placard?
    @State private var isChoosingTemplate = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Your placards")
                        .font(.largeTitle.bold())
                    Text("Swipe through the signs you’ve made.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 28)

                Spacer()
                PlacardDeck(placards: placards, onOpen: { selectedPlacard = $0 }, onCycle: cyclePlacards)
                Spacer()

                Button { isChoosingTemplate = true } label: {
                    Label("Create a placard", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.black)
                .controlSize(.large)
                .padding(24)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationDestination(isPresented: Binding(
                get: { selectedPlacard != nil },
                set: { if !$0 { selectedPlacard = nil } }
            )) {
                if let selected = selectedPlacard {
                    ContentView(placard: binding(for: selected.id))
                        .onDisappear { PlacardStore.save(placards) }
                }
            }
            .sheet(isPresented: $isChoosingTemplate) {
                TemplatePicker { template in
                    let newPlacard = Placard(sign: template.makeSign())
                    placards.insert(newPlacard, at: 0)
                    selectedPlacard = newPlacard
                    isChoosingTemplate = false
                }
            }
            .onChange(of: placards) { _, newValue in PlacardStore.save(newValue) }
        }
    }

    private func cyclePlacards() {
        guard placards.count > 1 else { return }
        placards.append(placards.removeFirst())
    }

    private func binding(for id: UUID) -> Binding<Placard> {
        Binding(
            get: { placards.first(where: { $0.id == id })! },
            set: { updated in
                guard let index = placards.firstIndex(where: { $0.id == id }) else { return }
                placards[index] = updated
            }
        )
    }
}

private struct PlacardDeck: View {
    let placards: [Placard]
    let onOpen: (Placard) -> Void
    let onCycle: () -> Void
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        ZStack {
            ForEach(Array(placards.prefix(3).enumerated()), id: \.element.id) { index, placard in
                SignRenderer(sign: placard.sign)
                    .frame(width: 290, height: 145)
                    .shadow(color: .black.opacity(index == 0 ? 0.22 : 0.08), radius: 16, y: 10)
                    .rotationEffect(.degrees(index == 0 ? Double(dragOffset.width / 22) : -Double(index * 4)))
                    .offset(x: index == 0 ? dragOffset.width : -CGFloat(index * 15), y: -CGFloat(index * 11))
                    .zIndex(Double(10 - index))
                    .gesture(index == 0 ? DragGesture()
                        .onChanged { dragOffset = $0.translation }
                        .onEnded { value in
                            if abs(value.translation.width) > 55 { onCycle() }
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { dragOffset = .zero }
                        } : nil)
                    .onTapGesture { if index == 0 { onOpen(placard) } }
            }
        }
        .frame(width: 340, height: 190)
        .accessibilityLabel("Placard stack")
        .accessibilityHint("Swipe to browse saved placards. Tap the front placard to edit it.")
    }
}

private enum PlaceholderTemplate: CaseIterable, Identifiable {
    case yellowRoute, midnight, bold, sunset
    var id: Self { self }
    var title: String {
        switch self {
        case .yellowRoute: "Yellow route"
        case .midnight: "Midnight"
        case .bold: "Bold"
        case .sunset: "Sunset"
        }
    }

    func makeSign() -> SignDraft {
        var sign = SignDraft.fallback
        switch self {
        case .yellowRoute:
            sign.background = .yellowArch
            sign.layers[0].text = "PASADA"
            sign.layers[0].font = .wide
            sign.layers[0].color = SignColor(red: 0.12, green: 0.05, blue: 0.03)
            sign.layers[0].gradientColor = sign.layers[0].color
            sign.layers[0].y = 0.35
            sign.layers[1].text = "KAYA BA?"
            sign.layers[1].font = .regular
            sign.layers[1].color = SignColor(red: 0.75, green: 0.08, blue: 0.05)
            sign.layers[1].gradientColor = sign.layers[1].color
            sign.layers[1].y = 0.69
        case .midnight:
            sign.layers[0].color = .lime
            sign.layers[1].color = .pink
        case .bold:
            sign.layers[0].color = .pink
            sign.layers[1].color = .lime
        case .sunset:
            sign.layers[0].color = SignColor(red: 1, green: 0.57, blue: 0.05)
            sign.layers[0].gradientColor = .pink
            sign.layers[0].usesGradient = true
            sign.layers[1].color = SignColor(red: 1, green: 0.84, blue: 0.11)
        }
        return sign
    }
}

private struct TemplatePicker: View {
    let choose: (PlaceholderTemplate) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Start with a real yellow route placard, then add your next templates here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ForEach(PlaceholderTemplate.allCases) { template in
                        Button { choose(template) } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                SignRenderer(sign: template.makeSign())
                                    .aspectRatio(2, contentMode: .fit)
                                    .frame(maxWidth: .infinity)
                                Text(template.title).font(.headline).foregroundStyle(.primary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Choose a template")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
