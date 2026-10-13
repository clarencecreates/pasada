import WidgetKit
import SwiftUI

struct WidyipEntry: TimelineEntry {
    let date: Date
    let sign: SignDraft
}

struct WidyipTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> WidyipEntry { WidyipEntry(date: .now, sign: .fallback) }
    func getSnapshot(in context: Context, completion: @escaping (WidyipEntry) -> Void) { completion(WidyipEntry(date: .now, sign: SignStore.load())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<WidyipEntry>) -> Void) {
        completion(Timeline(entries: [WidyipEntry(date: .now, sign: SignStore.load())], policy: .never))
    }
}

struct WidyipWidget: Widget {
    let kind = "WidyipWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WidyipTimelineProvider()) { entry in
            SignRenderer(sign: entry.sign)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Jeepney Sign")
        .description("A custom sign for your Home Screen.")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

@main
struct WidyipWidgetBundle: WidgetBundle {
    var body: some Widget { WidyipWidget() }
}
