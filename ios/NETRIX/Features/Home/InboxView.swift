import SwiftUI

/// Notifications inbox behind the bell on Home: reports published, review progress,
/// analyst requests and coach feedback, newest first.
struct InboxView: View {
    @EnvironmentObject private var store: GoalieStore
    @EnvironmentObject private var uploads: UploadManager
    @Environment(\.dismiss) private var dismiss
    @State private var seenBefore: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            AppBar(title: "Notifications", onBack: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: NX.S.m) {
                    if uploads.job != nil { UploadStatusCard() }
                    if store.inbox.isEmpty {
                        EmptyStateCard(icon: "bell", title: "You're all caught up",
                                       message: "Reports, analyst updates and coach feedback will show up here.")
                            .padding(.top, NX.S.xl)
                    } else {
                        ForEach(store.inbox) { item in
                            if let route = item.route {
                                NavigationLink(value: route) { row(item) }.buttonStyle(.plain)
                            } else {
                                row(item)
                            }
                        }
                    }
                }
                .padding(.horizontal, NX.margin).padding(.bottom, NX.S.xxl)
            }
            .refreshable { if let id = store.goalieId { await store.load(goalieId: id, force: true) } }
        }
        .nxScreen()
        .onAppear {
            seenBefore = UserDefaults.standard.double(forKey: "inbox.seen.\(store.goalieId ?? "")")
            store.markInboxSeen()
        }
    }

    private func row(_ item: GoalieStore.InboxItem) -> some View {
        let unread = seenBefore > 0 && item.date.timeIntervalSince1970 > seenBefore
        let (icon, tint) = style(item.kind)
        return HStack(alignment: .top, spacing: NX.S.m) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 36, height: 36).background(Circle().fill(tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.title).font(.nxLabel).foregroundStyle(.white)
                    Spacer()
                    Text(Fmt.relative(item.date)).font(.nxCaption).foregroundStyle(NX.textMuted)
                }
                Text(item.body).font(.nxBodyS).foregroundStyle(NX.textSecondary).lineLimit(3).multilineTextAlignment(.leading)
            }
            if unread { Circle().fill(NX.ice).frame(width: 8, height: 8).padding(.top, 6) }
        }
        .nxCard(padding: 14, radius: NX.R.lg)
        .accessibilityElement(children: .combine)
    }

    private func style(_ k: GoalieStore.InboxItem.Kind) -> (String, Color) {
        switch k {
        case .report: ("chart.bar.fill", NX.success)
        case .review: ("eye", NX.info)
        case .attention: ("exclamationmark.circle", NX.error)
        case .feedback: ("text.bubble", NX.ice)
        case .submitted: ("tray.and.arrow.up", NX.warning)
        }
    }
}
