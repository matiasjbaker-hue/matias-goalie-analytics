import Foundation
import WidgetKit

/// Keeps the home/lock screen widget in step with the app's data.
enum WidgetBridge {
    @MainActor
    static func publish(store: GoalieStore) {
        let season = SummaryMetrics(games: store.seasonGames)
        let pending = store.requests.first.map { r -> WidgetSnapshot.Pending in
            let status: String
            switch r.reviewStatus { case .inReview: status = "In review"; case .needsAttention: status = "Needs action"; default: status = "Pending" }
            return .init(opponent: r.requested?.opponent ?? "Your game", status: status)
        }
        let last = store.games.first.map {
            WidgetSnapshot.LastGame(opponent: $0.game.opponentName, date: $0.game.date, svPct: $0.svPct, gameId: $0.game.id.value)
        }
        let snap = WidgetSnapshot(goalieName: store.profile?.fullName ?? "", seasonSvPct: season.svPct, gsax: season.gsax,
                                  gamesCount: season.count, recentSv: store.games.prefix(8).reversed().compactMap(\.svPct),
                                  lastGame: last, pending: pending, updatedAt: Date())
        save(snap)
    }

    /// Background refresh path: only game totals are fetched, so shot-based numbers keep their last value.
    static func publish(goalieId: String, games: [Game]) async {
        let metrics = games.map { GameMetrics(game: $0, shots: [], rebound: nil) }
            .sorted { ($0.game.date ?? .distantPast) > ($1.game.date ?? .distantPast) }
        var snap = WidgetSnapshot.load() ?? WidgetSnapshot(goalieName: "", seasonSvPct: nil, gsax: nil, gamesCount: 0,
                                                           recentSv: [], lastGame: nil, pending: nil, updatedAt: Date())
        // Season totals stay as the app last computed them (they depend on the profile's season).
        snap.recentSv = metrics.prefix(8).reversed().compactMap(\.svPct)
        if let g = metrics.first { snap.lastGame = .init(opponent: g.game.opponentName, date: g.game.date, svPct: g.svPct, gameId: g.game.id.value) }
        snap.updatedAt = Date()
        save(snap)
    }

    private static func save(_ snap: WidgetSnapshot) {
        guard snap != WidgetSnapshot.load() else { return }
        snap.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func clear() {
        SharedConfig.defaults?.removeObject(forKey: SharedConfig.snapshotKey)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
