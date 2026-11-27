import WidgetKit
import SwiftUI
import ActivityKit

@main
struct NetrixWidgetBundle: WidgetBundle {
    init() { FontLoader.registerBundledFonts() }
    var body: some Widget {
        NetrixStatsWidget()
        FilmUploadLiveActivity()
    }
}

struct StatsEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct StatsProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatsEntry { StatsEntry(date: Date(), snapshot: .placeholder) }

    func getSnapshot(in context: Context, completion: @escaping (StatsEntry) -> Void) {
        completion(StatsEntry(date: Date(), snapshot: context.isPreview ? (WidgetSnapshot.load() ?? .placeholder) : WidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatsEntry>) -> Void) {
        // The app reloads the widget whenever its data changes; this is a fallback refresh.
        let entry = StatsEntry(date: Date(), snapshot: WidgetSnapshot.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60 * 60))))
    }
}

struct NetrixStatsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NetrixStats", provider: StatsProvider()) { entry in
            StatsEntryView(entry: entry)
        }
        .configurationDisplayName("Season stats")
        .description("Your season save percentage, last report and film in review.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct StatsEntryView: View {
    let entry: StatsEntry
    @Environment(\.widgetFamily) private var family

    private var url: URL {
        if entry.snapshot?.pending != nil && family != .systemSmall { return URL(string: "netrix://inbox")! }
        if let g = entry.snapshot?.lastGame, family == .systemMedium { return URL(string: "netrix://game/\(g.gameId)")! }
        return URL(string: entry.snapshot?.gamesCount ?? 0 > 0 ? "netrix://stats" : "netrix://submit")!
    }

    var body: some View {
        StatsWidgetView(snap: entry.snapshot, family: family)
            .widgetURL(url)
            .containerBackground(for: .widget) {
                if family == .systemSmall || family == .systemMedium { NXBackground() } else { Color.clear }
            }
    }
}

struct FilmUploadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FilmUploadAttributes.self) { context in
            UploadActivityView(opponent: context.attributes.opponent, fileSize: context.attributes.fileSize,
                               progress: context.state.progress, phase: context.state.phase)
                .activityBackgroundTint(Color(hex: 0x08090D))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "netrix://inbox"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    NetrixMark().fill(.white).frame(width: 34, height: 16).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.phase == "done" ? "Done" : "\(Int(context.state.progress * 100))%")
                        .font(.sora(15, .semibold)).foregroundStyle(NX.ice)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.state.phase == "done" ? "Game submitted" : "Uploading vs \(context.attributes.opponent)")
                            .font(.sora(13, .semibold)).foregroundStyle(.white)
                        ProgressView(value: context.state.progress).tint(NX.ice)
                    }
                }
            } compactLeading: {
                NetrixMark().fill(.white).frame(width: 22, height: 10)
            } compactTrailing: {
                Text(context.state.phase == "done" ? "✓" : "\(Int(context.state.progress * 100))%").font(.sora(12, .semibold)).foregroundStyle(NX.ice)
            } minimal: {
                ProgressView(value: context.state.progress).progressViewStyle(.circular).tint(NX.ice)
            }
            .widgetURL(URL(string: "netrix://inbox"))
        }
    }
}
