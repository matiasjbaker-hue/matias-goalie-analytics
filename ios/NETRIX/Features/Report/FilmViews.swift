import SwiftUI
import AVKit

/// What to play: a film (game video id) from a given second.
struct FilmCue: Identifiable, Hashable {
    let id = UUID()
    let videoId: String
    let start: Double
    let title: String
}

/// Film section of a game report: the full game, every goal against, and coach moments.
struct GameFilmSection: View {
    let metrics: GameMetrics
    @EnvironmentObject private var store: GoalieStore
    @State private var films: [GameVideo] = []
    @State private var moments: [CoachMoment] = []
    @State private var loaded = false
    @State private var cue: FilmCue?

    var body: some View {
        Group {
            if !loaded {
                SkeletonBlock(height: 56)
            } else if films.isEmpty && metrics.goalClips.isEmpty {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: NX.S.m) {
                    SectionHeader(title: "Film")
                    if let first = films.first {
                        Button { cue = FilmCue(videoId: first.id.value, start: 0, title: "vs \(metrics.game.opponentName)") } label: {
                            HStack(spacing: NX.S.m) {
                                FilmThumb(size: 52)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Watch full game").font(.sora(15, .semibold)).foregroundStyle(.white)
                                    Text(films.count > 1 ? "\(films.count) parts" : "Game film").font(.nxCaption).foregroundStyle(NX.textMuted)
                                }
                                Spacer()
                                Image(systemName: "play.circle.fill").font(.system(size: 28)).foregroundStyle(NX.ice)
                            }
                        }
                        .buttonStyle(.plain)
                        .nxCard(padding: 12, radius: 20)
                    }
                    if !metrics.goalClips.isEmpty {
                        Overline("Goals against", color: NX.textMuted).padding(.top, 4)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: NX.S.s) {
                                ForEach(Array(metrics.goalClips.enumerated()), id: \.offset) { i, clip in
                                    Button {
                                        cue = FilmCue(videoId: clip.videoId, start: max(0, clip.start - 4), title: "Goal \(i + 1)")
                                    } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            ZStack {
                                                RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06))
                                                Image(systemName: "play.fill").foregroundStyle(.white)
                                            }
                                            .frame(width: 124, height: 72)
                                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(NX.borderSubtle))
                                            Text(timeLabel(clip.start)).font(.sora(12, .semibold)).foregroundStyle(NX.ice)
                                            Text("Goal \(i + 1)\(clip.period.map { " · P\($0)" } ?? "")").font(.nxCaption).foregroundStyle(NX.textSecondary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Play goal \(i + 1)")
                                }
                            }
                        }
                    }
                    if !moments.isEmpty {
                        Overline("Coach moments", color: NX.textMuted).padding(.top, 4)
                        VStack(spacing: 0) {
                            ForEach(moments) { m in
                                Button {
                                    if let v = m.gameVideoId { cue = FilmCue(videoId: v, start: max(0, m.seconds - 5), title: m.title ?? "Coach moment") }
                                } label: {
                                    HStack(spacing: NX.S.m) {
                                        Text(timeLabel(m.seconds)).font(.sora(12, .semibold)).foregroundStyle(NX.ice).frame(width: 54, alignment: .leading)
                                        Text(m.title ?? "Moment").font(.nxBody).foregroundStyle(.white).lineLimit(2)
                                        Spacer()
                                        Image(systemName: "play.fill").font(.system(size: 11)).foregroundStyle(NX.textMuted)
                                    }
                                    .padding(.vertical, 12)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, NX.S.l)
                        .nxCard(padding: 0, radius: 20)
                    }
                }
            }
        }
        .task { await load() }
        .fullScreenCover(item: $cue) { FilmPlayerView(cue: $0) }
    }

    private func timeLabel(_ s: Double) -> String {
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    private func load() async {
        guard !loaded else { return }
        let gid = metrics.game.id.value
        let db = SupabaseClient.shared
        films = (try? await db.select("game_videos",
            query: "game_id=eq.\(gid)&or=(status.is.null,status.neq.clip)&select=*&order=part_order.asc.nullsfirst,created_at.asc")) ?? []
        if let goalie = store.goalieId {
            moments = (try? await db.select("coach_moments", query: "goalie_id=eq.\(goalie)&game_id=eq.\(gid)&select=*&order=t_seconds.asc")) ?? []
        }
        loaded = true
    }
}

/// Full-screen player: fetches a short-lived signed link, then streams from the cue point.
struct FilmPlayerView: View {
    let cue: FilmCue
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var error: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player).ignoresSafeArea()
            } else if let error {
                VStack(spacing: NX.S.m) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 28)).foregroundStyle(NX.error)
                    Text(error).font(.nxBody).foregroundStyle(.white).multilineTextAlignment(.center)
                }
                .padding(NX.S.x3).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                CircleIconButton(systemName: "xmark") { player?.pause(); dismiss() }.accessibilityLabel("Close")
                Text(cue.title).font(.nxLabel).foregroundStyle(.white)
            }
            .padding(NX.margin)
        }
        .task {
            do {
                let url = try await APIClient.watchURL(gameVideoId: cue.videoId)
                try? AVAudioSession.sharedInstance().setCategory(.playback)
                let p = AVPlayer(url: url)
                if cue.start > 0 { await p.seek(to: CMTime(seconds: cue.start, preferredTimescale: 600)) }
                player = p
                p.play()
            } catch {
                self.error = error.localizedDescription
                Haptics.error()
            }
        }
        .onDisappear { player?.pause() }
    }
}
