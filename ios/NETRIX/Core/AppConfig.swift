import Foundation

/// Fixed endpoints the app talks to. These are the same services the website uses:
/// Supabase for accounts and data (row-level security protects every row), and the
/// site's serverless API for video upload, film links and account deletion.
enum AppConfig {
    static let supabaseURL = URL(string: "https://iiuqxxrrruvwvfehrzic.supabase.co")!
    /// Publishable key: safe to ship in the app. RLS is what protects the data.
    static let supabaseKey = "sb_publishable_b8r2Nb1BWv4cndNyEJ75dA_o40__ZPQ"

    static let apiBaseURL = URL(string: "https://www.goalieiqanalytics.com")!

    static let termsURL = apiBaseURL.appending(path: "terms.html")
    static let privacyURL = apiBaseURL.appending(path: "privacy.html")
    /// Password reset links land on the website, which already handles recovery.
    static let passwordResetRedirect = apiBaseURL

    static let supportEmail = "goalieiqanalytics@gmail.com"

    /// Background URLSession identifier for game film uploads.
    static let uploadSessionID = "com.alkhaldi.netrix.film-upload"
}
