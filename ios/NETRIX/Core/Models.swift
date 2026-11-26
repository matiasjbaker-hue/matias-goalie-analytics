import Foundation

// MARK: - Lenient decoding helpers
// Columns in the existing database were added over time and some hold numbers as
// text, so every numeric/ID field decodes from either form.

struct FlexID: Codable, Hashable, CustomStringConvertible {
    let value: String
    var description: String { value }
    init(_ value: String) { self.value = value }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int64.self) { value = String(i) }
        else if let s = try? c.decode(String.self) { value = s }
        else if let d = try? c.decode(Double.self) { value = String(Int64(d)) }
        else { throw DecodingError.typeMismatch(String.self, .init(codingPath: decoder.codingPath, debugDescription: "id")) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let i = Int64(value) { try c.encode(i) } else { try c.encode(value) }
    }
}

extension KeyedDecodingContainer {
    func flexDouble(_ key: Key) -> Double? {
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return d }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Double(s.trimmingCharacters(in: .whitespaces)) }
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b ? 1 : 0 }
        return nil
    }
    func flexInt(_ key: Key) -> Int? { flexDouble(key).map { Int($0.rounded()) } }
    func flexString(_ key: Key) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? decodeIfPresent(Int64.self, forKey: key) { return String(i) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return String(d) }
        return nil
    }
    func flexBool(_ key: Key) -> Bool? {
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b }
        if let i = flexInt(key) { return i != 0 }
        return nil
    }
}

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

enum DateParse {
    static let day: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let iso = ISO8601DateFormatter()

    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if s.count == 10, let d = day.date(from: s) { return d }
        if let d = isoFrac.date(from: s) { return d }
        if let d = iso.date(from: s) { return d }
        // Postgres timestamptz without "T"
        let tFixed = s.replacingOccurrences(of: " ", with: "T")
        if let d = isoFrac.date(from: tFixed) ?? iso.date(from: tFixed) { return d }
        return day.date(from: String(s.prefix(10)))
    }
}

// MARK: - Profile

enum Role: String, Codable { case goalie, coach, admin }

struct Profile: Decodable, Identifiable, Equatable {
    let id: String
    var fullName: String?
    var role: Role
    var team: String?
    var season: String?
    var birthYear: Int?
    var catches: String?
    var heightIn: Int?
    var weightLbs: Int?
    var level: String?
    var league: String?
    /// Small square photo stored as a data URL (same column the website uses).
    var avatarURL: String?

    var firstName: String { (fullName ?? "").split(separator: " ").first.map(String.init) ?? "" }
    var lastName: String { (fullName ?? "").split(separator: " ").dropFirst().joined(separator: " ") }
    var initials: String {
        let parts = (fullName ?? "").split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first }.map { String($0).uppercased() }
        return letters.isEmpty ? "N" : letters.joined()
    }
    /// The onboarding steps fill these; an account without them is sent through setup.
    var needsSetup: Bool { role == .goalie && (catches == nil || (team ?? "").isEmpty) }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = c.flexString(AnyKey("id")) ?? ""
        fullName = c.flexString(AnyKey("full_name"))
        role = Role(rawValue: c.flexString(AnyKey("role")) ?? "goalie") ?? .goalie
        team = c.flexString(AnyKey("team"))
        season = c.flexString(AnyKey("season"))
        birthYear = c.flexInt(AnyKey("birth_year"))
        catches = c.flexString(AnyKey("catches"))
        heightIn = c.flexInt(AnyKey("height_in"))
        weightLbs = c.flexInt(AnyKey("weight_lbs"))
        level = c.flexString(AnyKey("level"))
        league = c.flexString(AnyKey("league"))
        avatarURL = c.flexString(AnyKey("avatar_url"))
    }
}

/// Sets or clears the profile photo (`null` removes it).
struct AvatarPatch: Encodable {
    let avatar_url: String?
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        if let avatar_url { try c.encode(avatar_url, forKey: AnyKey("avatar_url")) }
        else { try c.encodeNil(forKey: AnyKey("avatar_url")) }
    }
}

struct ProfilePatch: Encodable {
    var full_name: String?
    var team: String?
    var birth_year: Int?
    var catches: String?
    var height_in: Int?
    var weight_lbs: Int?
    var level: String?
    var league: String?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        if let full_name { try c.encode(full_name, forKey: AnyKey("full_name")) }
        if let team { try c.encode(team, forKey: AnyKey("team")) }
        if let birth_year { try c.encode(birth_year, forKey: AnyKey("birth_year")) }
        if let catches { try c.encode(catches, forKey: AnyKey("catches")) }
        if let height_in { try c.encode(height_in, forKey: AnyKey("height_in")) }
        if let weight_lbs { try c.encode(weight_lbs, forKey: AnyKey("weight_lbs")) }
        if let level { try c.encode(level, forKey: AnyKey("level")) }
        if let league { try c.encode(league, forKey: AnyKey("league")) }
    }
}

// MARK: - Games and shots

struct Game: Decodable, Identifiable, Hashable {
    let id: FlexID
    let userId: String?
    let dateString: String?
    let opponent: String?
    let homeAway: String?
    let teamGoals: Int?
    let opponentGoals: Int?
    let shotsAgainst: Int?
    let saves: Int?
    let goalsAgainst: Int?
    let minutesPlayed: Double?
    let gameLength: Double?
    let season: String?
    let team: String?

    var date: Date? { DateParse.parse(dateString) }
    var opponentName: String { (opponent?.isEmpty == false ? opponent! : "Opponent") }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = (try? c.decode(FlexID.self, forKey: AnyKey("id"))) ?? FlexID(UUID().uuidString)
        userId = c.flexString(AnyKey("user_id"))
        dateString = c.flexString(AnyKey("date"))
        opponent = c.flexString(AnyKey("opponent"))
        homeAway = c.flexString(AnyKey("home_away"))
        teamGoals = c.flexInt(AnyKey("team_goals"))
        opponentGoals = c.flexInt(AnyKey("opponent goals")) ?? c.flexInt(AnyKey("opponent_goals"))
        shotsAgainst = c.flexInt(AnyKey("shots_against"))
        saves = c.flexInt(AnyKey("saves"))
        goalsAgainst = c.flexInt(AnyKey("goals_against"))
        minutesPlayed = c.flexDouble(AnyKey("minutes_played"))
        gameLength = c.flexDouble(AnyKey("game_length"))
        season = c.flexString(AnyKey("season"))
        team = c.flexString(AnyKey("team"))
    }
}

struct Shot: Decodable, Hashable {
    let gameId: String?
    let outcome: String?
    let xg: Double?
    let grade: String?
    let rebound: String?
    let strength: String?
    let period: String?
    /// Where the shot sits in the game film, when it was tagged from video.
    let gameVideoId: String?
    let clipStart: Double?

    var isGoal: Bool { (outcome ?? "").lowercased() == "goal" }
    var isHighDanger: Bool { grade == "A+" || grade == "A" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        gameId = c.flexString(AnyKey("game_id"))
        outcome = c.flexString(AnyKey("outcome"))
        xg = c.flexDouble(AnyKey("xg"))
        grade = c.flexString(AnyKey("xg_grade"))
        rebound = c.flexString(AnyKey("rebound"))
        strength = c.flexString(AnyKey("strength"))
        period = c.flexString(AnyKey("period"))
        gameVideoId = c.flexString(AnyKey("game_video_id"))
        clipStart = c.flexDouble(AnyKey("clip_start_seconds"))
    }
}

/// A moment a coach flagged in the game film.
struct CoachMoment: Decodable, Identifiable, Hashable {
    let id: FlexID
    let gameId: String?
    let gameVideoId: String?
    let seconds: Double
    let title: String?
    let authorName: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = (try? c.decode(FlexID.self, forKey: AnyKey("id"))) ?? FlexID(UUID().uuidString)
        gameId = c.flexString(AnyKey("game_id"))
        gameVideoId = c.flexString(AnyKey("game_video_id"))
        seconds = c.flexDouble(AnyKey("t_seconds")) ?? 0
        title = c.flexString(AnyKey("title"))
        authorName = c.flexString(AnyKey("author_name"))
    }
}

struct ReboundControl: Decodable, Hashable {
    let gameId: String?
    let good: Int
    let bad: Int
    let goalsFromRebounds: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        gameId = c.flexString(AnyKey("game_id"))
        func n(_ k: String) -> Int { c.flexInt(AnyKey(k)) ?? 0 }
        good = n("blocker_good") + n("midsection_good") + n("pad_stick_good")
        bad = n("blocker_bad") + n("midsection_bad") + n("pad_stick_bad")
        goalsFromRebounds = n("blocker_goal") + n("midsection_goal") + n("pad_stick_goal") + n("glove_goal")
    }
}

// MARK: - Film requests

struct RequestedGame: Codable, Hashable {
    var date: String?
    var opponent: String?
    var home_away: String?
    var team_goals: Int?
    var opponent_goals: Int?
    var season: String?
    /// Extra context from the app for the analyst. Stored alongside the game details.
    var goalie_note: String?
    var focus_areas: [String]?
    var shots_faced: Int?
    var saves: Int?
    var minutes_played: Int?
}

enum ReviewStatus: String {
    case received, inReview = "in_review", approved, needsAttention = "needs_attention"
}

struct GameVideo: Decodable, Identifiable, Hashable {
    let id: FlexID
    let userId: String?
    let gameId: String?
    let requested: RequestedGame?
    let status: String?
    let reviewStatus: ReviewStatus
    let createdAt: Date?
    let approvedAt: Date?
    let adminNote: String?
    let parentVideoId: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = (try? c.decode(FlexID.self, forKey: AnyKey("id"))) ?? FlexID(UUID().uuidString)
        userId = c.flexString(AnyKey("user_id"))
        gameId = c.flexString(AnyKey("game_id"))
        requested = try? c.decodeIfPresent(RequestedGame.self, forKey: AnyKey("requested_game"))
        status = c.flexString(AnyKey("status"))
        reviewStatus = ReviewStatus(rawValue: c.flexString(AnyKey("review_status")) ?? "received") ?? .received
        createdAt = DateParse.parse(c.flexString(AnyKey("created_at")))
        approvedAt = DateParse.parse(c.flexString(AnyKey("approved_at")))
        adminNote = c.flexString(AnyKey("admin_note"))
        parentVideoId = c.flexString(AnyKey("parent_video_id"))
    }
}

struct CoachNote: Decodable, Identifiable, Hashable {
    let id: FlexID
    let text: String
    let gameId: String?
    let createdAt: Date?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = (try? c.decode(FlexID.self, forKey: AnyKey("id"))) ?? FlexID(UUID().uuidString)
        text = c.flexString(AnyKey("text")) ?? ""
        gameId = c.flexString(AnyKey("game_id"))
        createdAt = DateParse.parse(c.flexString(AnyKey("created_at")))
    }
}

struct GoalieAccess: Decodable, Hashable {
    let plan: String?
    let status: String?
    let gameCredits: Int?
    let accessUntil: Date?

    var isActive: Bool {
        guard let status, ["comp", "trial", "active"].contains(status) else { return false }
        return accessUntil.map { $0 > Date() } ?? true
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        plan = c.flexString(AnyKey("plan"))
        status = c.flexString(AnyKey("status"))
        gameCredits = c.flexInt(AnyKey("game_credits"))
        accessUntil = DateParse.parse(c.flexString(AnyKey("access_until")))
    }
}

struct CoachAssignment: Decodable, Hashable {
    let goalieId: String
    let active: Bool
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        goalieId = c.flexString(AnyKey("goalie_id")) ?? ""
        active = c.flexBool(AnyKey("active")) ?? true
    }
}
