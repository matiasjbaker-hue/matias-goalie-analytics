import SwiftUI
import WidgetKit

/// Home and lock screen widget layouts (shared so the app can preview them).
struct StatsWidgetView: View {
    let snap: WidgetSnapshot?
    let family: WidgetFamily

    var body: some View {
        switch family {
        case .systemMedium: medium
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        default: small
        }
    }

    private var sv: String { snap?.seasonSvPct.map { String(format: "%.1f", $0) } ?? "—" }
    private var fraction: Double { snap?.seasonSvPct.map { min(max(($0 - 80) / 20, 0), 1) } ?? 0 }

    // MARK: Home screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                NetrixMark().fill(.white).frame(width: 30, height: 14)
                Spacer()
                if let p = snap?.pending { StatusDot(status: p.status) }
            }
            Spacer(minLength: 4)
            if let snap, snap.gamesCount > 0 {
                Text(sv).font(.sora(40, .light)).foregroundStyle(.white).minimumScaleFactor(0.7).lineLimit(1)
                Text("Season save %").font(.sora(11)).foregroundStyle(NX.textSecondary)
                MiniSpark(values: snap.recentSv).frame(height: 22).padding(.top, 8)
            } else {
                Text(snap == nil ? "Log in to NETRIX" : "No games yet").font(.sora(15, .semibold)).foregroundStyle(.white)
                Text(snap == nil ? "Your stats show here." : "Submit a game to see your stats.").font(.sora(11)).foregroundStyle(NX.textSecondary)
            }
        }
    }

    private var medium: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 9)
                Circle().trim(from: 0, to: fraction).stroke(NX.ice, style: StrokeStyle(lineWidth: 9, lineCap: .round)).rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text(sv).font(.sora(24, .light)).foregroundStyle(.white).minimumScaleFactor(0.6)
                    Text("SV%").font(.sora(9, .semibold)).tracking(1).foregroundStyle(NX.textMuted)
                }
            }
            .frame(width: 104, height: 104)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    NetrixMark().fill(.white).frame(width: 26, height: 12)
                    Text("\(snap?.gamesCount ?? 0) games").font(.sora(11)).foregroundStyle(NX.textMuted)
                }
                if let g = snap?.lastGame {
                    Text("LAST GAME").font(.sora(9, .semibold)).tracking(1.1).foregroundStyle(NX.ice)
                    Text("vs \(g.opponent)").font(.sora(15, .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(g.svPct.map { String(format: "%.1f%% save percentage", $0) } ?? "Report ready").font(.sora(11)).foregroundStyle(NX.textSecondary)
                } else {
                    Text("No reports yet").font(.sora(15, .semibold)).foregroundStyle(.white)
                }
                if let p = snap?.pending {
                    HStack(spacing: 6) {
                        StatusDot(status: p.status)
                        Text("\(p.status) · vs \(p.opponent)").font(.sora(11)).foregroundStyle(NX.textSecondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Lock screen

    private var circular: some View {
        Gauge(value: fraction) {
            Text("SV")
        } currentValueLabel: {
            Text(snap?.seasonSvPct.map { String(format: "%.0f", $0) } ?? "—")
        }
        .gaugeStyle(.accessoryCircular)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("NETRIX").font(.sora(11, .bold)).widgetAccentable()
            Text("\(sv)% season SV").font(.sora(14, .semibold))
            if let p = snap?.pending { Text("\(p.status): vs \(p.opponent)").font(.sora(11)).lineLimit(1) }
            else if let g = snap?.lastGame { Text("Last: vs \(g.opponent)").font(.sora(11)).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inline: some View {
        Text(snap?.pending.map { "NETRIX · \($0.status)" } ?? "NETRIX · \(sv)% SV")
    }
}

struct StatusDot: View {
    let status: String
    var color: Color {
        switch status { case "In review": NX.info; case "Needs action": NX.error; default: NX.warning }
    }
    var body: some View { Circle().fill(color).frame(width: 7, height: 7) }
}

struct MiniSpark: View {
    let values: [Double]
    var body: some View {
        GeometryReader { geo in
            if values.count > 1, let lo = values.min(), let hi = values.max() {
                let span = max(hi - lo, 0.001)
                let pts = values.enumerated().map { i, v in
                    CGPoint(x: geo.size.width * CGFloat(i) / CGFloat(values.count - 1),
                            y: geo.size.height - 2 - (geo.size.height - 4) * CGFloat((v - lo) / span))
                }
                Path { p in p.move(to: pts[0]); pts.dropFirst().forEach { p.addLine(to: $0) } }
                    .stroke(NX.ice, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                Circle().fill(.white).frame(width: 6, height: 6).position(pts.last!)
            }
        }
    }
}

/// Lock screen view of the film upload Live Activity.
struct UploadActivityView: View {
    let opponent: String
    let fileSize: String
    let progress: Double
    let phase: String

    var title: String {
        switch phase { case "done": "Game submitted"; case "failed": "Upload paused"; case "finishing": "Finishing upload"; default: "Uploading game film" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                NetrixMark().fill(.white).frame(width: 30, height: 14)
                Text(title).font(.sora(14, .semibold)).foregroundStyle(.white)
                Spacer()
                Text(phase == "done" ? "Done" : "\(Int(progress * 100))%").font(.sora(14, .semibold)).foregroundStyle(phase == "failed" ? NX.error : NX.ice)
            }
            ProgressView(value: progress).tint(phase == "failed" ? NX.error : NX.ice)
            Text(phase == "failed" ? "Open NETRIX to try again." : "vs \(opponent) · \(fileSize)").font(.sora(12)).foregroundStyle(NX.textSecondary)
        }
        .padding(16)
    }
}
