import SwiftUI

/// Renders a one-page NETRIX game report as a PDF to share (Messages, Mail, Files, AirDrop, print).
enum ReportExporter {
    @MainActor
    static func pdf(metrics: GameMetrics, season: SummaryMetrics, profile: Profile?, note: CoachNote?) -> URL? {
        let page = CGSize(width: 612, height: 792) // US Letter, points
        let view = ReportPage(metrics: metrics, season: season, profile: profile, note: note)
            .frame(width: page.width, height: page.height)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(page)
        let name = "NETRIX-report-vs-\(metrics.game.opponentName)-\(metrics.game.dateString ?? "game")"
            .replacingOccurrences(of: " ", with: "-")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted).joined()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).pdf")
        var ok = false
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: page)
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            ctx.beginPDFPage(nil)
            draw(ctx)
            ctx.endPDFPage()
            ctx.closePDF()
            ok = true
        }
        return ok ? url : nil
    }
}

private struct ReportPage: View {
    let metrics: GameMetrics
    let season: SummaryMetrics
    let profile: Profile?
    let note: CoachNote?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                NetrixLockup(height: 16)
                Spacer()
                Text("Game report").font(.sora(11, .semibold)).foregroundStyle(NX.textSecondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("vs \(metrics.game.opponentName)").font(.sora(30, .bold)).foregroundStyle(.white)
                Text(subtitle).font(.sora(12)).foregroundStyle(NX.textSecondary)
            }
            HStack(spacing: 24) {
                ScoreRing(fraction: svRingFraction(metrics.svPct), value: Fmt.pct(metrics.svPct), caption: "Save %", size: 120, lineWidth: 10, animated: false)
                VStack(alignment: .leading, spacing: 10) {
                    stat("Goals saved above expected", Fmt.signed(metrics.gsax))
                    stat("Season save %", Fmt.pct(season.svPct))
                    stat("High-danger save %", Fmt.pct(metrics.highDangerSvPct, digits: 0))
                }
            }
            HStack(spacing: 12) {
                box("Shots faced", "\(metrics.shotsAgainst)")
                box("Saves", "\(metrics.saves)")
                box("Goals against", "\(metrics.goals)")
                box("Rebound control", metrics.reboundGoodPct.map { "\(Fmt.pct($0, digits: 0))%" } ?? "—")
            }
            if !metrics.gradeCounts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Shots by grade").font(.sora(13, .semibold)).foregroundStyle(.white)
                    ForEach(["A+", "A", "B", "C"].filter { metrics.gradeCounts[$0] != nil }, id: \.self) { g in
                        let c = metrics.gradeCounts[g]!
                        HStack {
                            Text(g).font(.sora(12, .bold)).foregroundStyle(NX.ice).frame(width: 30, alignment: .leading)
                            Text("\(c.saves) of \(c.shots) saved").font(.sora(12)).foregroundStyle(NX.textSecondary)
                        }
                    }
                }
            }
            if let note {
                VStack(alignment: .leading, spacing: 6) {
                    Text("COACH FEEDBACK").font(.sora(10, .semibold)).tracking(1.2).foregroundStyle(NX.ice)
                    Text(note.text).font(.sora(12)).foregroundStyle(.white)
                }
            }
            Spacer()
            Text("Every number comes from the game's tagged shots and totals. Generated \(Fmt.longDate.string(from: Date())).")
                .font(.sora(9)).foregroundStyle(NX.textMuted)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NXBackground())
        .environment(\.colorScheme, .dark)
    }

    private var subtitle: String {
        [profile?.fullName, metrics.game.date.map { Fmt.longDate.string(from: $0) }, profile?.team, profile?.level]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.sora(9, .semibold)).tracking(1).foregroundStyle(NX.textMuted)
            Text(value).font(.sora(20, .semibold)).foregroundStyle(.white)
        }
    }

    private func box(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased()).font(.sora(8, .semibold)).tracking(1).foregroundStyle(NX.textMuted)
            Text(value).font(.sora(22, .light)).foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(NX.borderSubtle))
    }
}
