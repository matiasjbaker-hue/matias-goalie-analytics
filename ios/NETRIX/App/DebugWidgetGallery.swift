#if DEBUG
import SwiftUI
import WidgetKit

/// Debug-only (`-NXScreen widgets`): renders every widget size and the upload Live Activity.
struct DebugWidgetGallery: View {
    private let snap = WidgetSnapshot.placeholder
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Widgets").font(.nxH2).foregroundStyle(.white)
                HStack(spacing: 14) {
                    tile(.systemSmall, w: 158, h: 158)
                    tile(.systemSmall, w: 158, h: 158, snap: WidgetSnapshot(goalieName: "", seasonSvPct: nil, gsax: nil, gamesCount: 0, recentSv: [], lastGame: nil, pending: nil, updatedAt: Date()))
                }
                tile(.systemMedium, w: 338, h: 158)
                Text("Lock screen").font(.nxH3).foregroundStyle(.white)
                HStack(spacing: 14) {
                    StatsWidgetView(snap: snap, family: .accessoryCircular).frame(width: 72, height: 72)
                        .background(Circle().fill(Color.white.opacity(0.15)))
                    StatsWidgetView(snap: snap, family: .accessoryRectangular).frame(width: 170, height: 72)
                        .padding(.horizontal, 8).background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.15)))
                }
                .foregroundStyle(.white)
                Text("Live Activity").font(.nxH3).foregroundStyle(.white)
                UploadActivityView(opponent: "Bay Storm", fileSize: "2.4 GB", progress: 0.42, phase: "uploading")
                    .background(RoundedRectangle(cornerRadius: 22).fill(Color(hex: 0x08090D)))
            }
            .padding(20)
        }
        .background(LinearGradient(colors: [Color(hex: 0x3B5BB5), Color(hex: 0x1B2A55)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    private func tile(_ family: WidgetFamily, w: CGFloat, h: CGFloat, snap: WidgetSnapshot? = .placeholder) -> some View {
        StatsWidgetView(snap: snap, family: family)
            .padding(16)
            .frame(width: w, height: h)
            .background(NXBackground())
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
#endif
