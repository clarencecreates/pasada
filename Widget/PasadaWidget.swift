import WidgetKit
import SwiftUI

struct PasadaEntry: TimelineEntry {
    let date: Date
    let sign: SignDraft
}

struct PasadaTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> PasadaEntry { PasadaEntry(date: .now, sign: .fallback) }
    func getSnapshot(in context: Context, completion: @escaping (PasadaEntry) -> Void) { completion(PasadaEntry(date: .now, sign: SignStore.load())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PasadaEntry>) -> Void) {
        completion(Timeline(entries: [PasadaEntry(date: .now, sign: SignStore.load())], policy: .never))
    }
}

struct PasadaWidget: Widget {
    let kind = "PasadaWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PasadaTimelineProvider()) { entry in
            SignRenderer(sign: entry.sign)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Jeepney Sign")
        .description("A custom sign for your Home Screen.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

@main
struct PasadaWidgetBundle: WidgetBundle {
    var body: some Widget { PasadaWidget() }
}
