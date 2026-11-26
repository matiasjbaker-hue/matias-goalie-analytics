import Foundation

// MARK: - Errors

struct AppError: LocalizedError, Equatable {
    let message: String
    var status: Int? = nil
    var errorDescription: String? { message }

    static let network = AppError(message: "Couldn't reach NETRIX. Check your connection and try again.")
    static let signedOut = AppError(message: "Your session ended. Log in again.", status: 401)
}

// MARK: - Session

struct AuthUser: Codable, Equatable {
    let id: String
    let email: String?
}

struct AuthSession: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var user: AuthUser

    var isExpiringSoon: Bool { expiresAt.timeIntervalSinceNow < 60 }
}

private struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String
    let expires_in: Double?
    let expires_at: Double?
    let user: AuthUser

    var session: AuthSession {
        let expiry: Date
        if let at = expires_at { expiry = Date(timeIntervalSince1970: at) }
        else { expiry = Date().addingTimeInterval(expires_in ?? 3600) }
        return AuthSession(accessToken: access_token, refreshToken: refresh_token, expiresAt: expiry, user: user)
    }
}

// MARK: - Client

/// Talks to Supabase Auth (GoTrue) and the database (PostgREST) over plain HTTPS,
/// so the app ships with no third-party dependencies.
actor SupabaseClient {
    static let shared = SupabaseClient()

    private let keychainKey = "auth.session"
    private(set) var session: AuthSession?
    private var refreshTask: Task<AuthSession, Error>?

    private let decoder: JSONDecoder = JSONDecoder()
    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    init() {
        if let data = Keychain.get(keychainKey),
           let saved = try? JSONDecoder().decode(AuthSession.self, from: data) {
            session = saved
        }
    }

    // MARK: Session storage

    private func store(_ new: AuthSession?) {
        session = new
        if let new, let data = try? JSONEncoder().encode(new) {
            Keychain.set(data, for: keychainKey)
        } else {
            Keychain.delete(keychainKey)
        }
    }

    /// A valid access token, refreshing first if it is about to expire.
    func validSession() async throws -> AuthSession {
        guard let current = session else { throw AppError.signedOut }
        if !current.isExpiringSoon { return current }
        return try await refresh()
    }

    @discardableResult
    func refresh() async throws -> AuthSession {
        if let refreshTask { return try await refreshTask.value }
        guard let current = session else { throw AppError.signedOut }
        let task = Task<AuthSession, Error> {
            let body = ["refresh_token": current.refreshToken]
            let data = try await self.authRequest("token?grant_type=refresh_token", method: "POST", body: body)
            return try self.decoder.decode(TokenResponse.self, from: data).session
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let new = try await task.value
            store(new)
            return new
        } catch let error as AppError where error.status == 400 || error.status == 401 {
            store(nil)
            throw AppError.signedOut
        }
    }

    // MARK: Auth

    func signIn(email: String, password: String) async throws -> AuthSession {
        let data = try await authRequest("token?grant_type=password", method: "POST",
                                         body: ["email": email, "password": password])
        let new = try decoder.decode(TokenResponse.self, from: data).session
        store(new)
        return new
    }

    /// Returns a session when the project signs users straight in, or nil when the
    /// account must be confirmed by email first.
    func signUp(email: String, password: String, metadata: [String: String]) async throws -> AuthSession? {
        struct Body: Encodable { let email: String; let password: String; let data: [String: String] }
        let data = try await authRequest("signup", method: "POST",
                                         body: Body(email: email, password: password, data: metadata))
        if let token = try? decoder.decode(TokenResponse.self, from: data) {
            store(token.session)
            return token.session
        }
        return nil
    }

    func sendPasswordReset(email: String) async throws {
        var comps = URLComponents()
        comps.queryItems = [URLQueryItem(name: "redirect_to", value: AppConfig.passwordResetRedirect.absoluteString)]
        _ = try await authRequest("recover?\(comps.percentEncodedQuery ?? "")", method: "POST", body: ["email": email])
    }

    func updateUser(email: String? = nil, password: String? = nil) async throws {
        var body: [String: String] = [:]
        if let email { body["email"] = email }
        if let password { body["password"] = password }
        _ = try await authRequest("user", method: "PUT", body: body, authorized: true)
    }

    func signOut() async {
        if session != nil {
            _ = try? await authRequest("logout", method: "POST", body: [String: String](), authorized: true)
        }
        store(nil)
    }

    func clearLocalSession() { store(nil) }

    private func authRequest<B: Encodable>(_ path: String, method: String, body: B, authorized: Bool = false) async throws -> Data {
        var request = URLRequest(url: URL(string: "auth/v1/\(path)", relativeTo: AppConfig.supabaseURL)!)
        request.httpMethod = method
        request.setValue(AppConfig.supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authorized {
            let s = try await validSession()
            request.setValue("Bearer \(s.accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request)
    }

    // MARK: Database (PostgREST)

    func select<T: Decodable>(_ table: String, query: String) async throws -> [T] {
        let data = try await rest(table: table, query: query, method: "GET")
        return try decodeRows(data)
    }

    @discardableResult
    func insert<T: Decodable, B: Encodable>(_ table: String, _ row: B) async throws -> [T] {
        let data = try await rest(table: table, query: "", method: "POST", body: row,
                                  prefer: "return=representation")
        return try decodeRows(data)
    }

    func insertIgnoringResult<B: Encodable>(_ table: String, _ row: B) async throws {
        _ = try await rest(table: table, query: "", method: "POST", body: row, prefer: "return=minimal")
    }

    @discardableResult
    func update<T: Decodable, B: Encodable>(_ table: String, query: String, _ patch: B) async throws -> [T] {
        let data = try await rest(table: table, query: query, method: "PATCH", body: patch,
                                  prefer: "return=representation")
        return try decodeRows(data)
    }

    func rpc<B: Encodable>(_ name: String, _ args: B) async throws -> Data {
        try await rest(table: "rpc/\(name)", query: "", method: "POST", body: args)
    }

    private func decodeRows<T: Decodable>(_ data: Data) throws -> [T] {
        if data.isEmpty { return [] }
        do { return try decoder.decode([T].self, from: data) }
        catch {
            #if DEBUG
            print("Decode \(T.self) failed:", error)
            #endif
            throw AppError(message: "Something in your data couldn't be read. Pull to refresh, or contact support.")
        }
    }

    private func rest(table: String, query: String, method: String) async throws -> Data {
        try await rest(table: table, query: query, method: method, body: Optional<String>.none)
    }

    private func rest<B: Encodable>(table: String, query: String, method: String, body: B?, prefer: String? = nil) async throws -> Data {
        let s = try await validSession()
        let encodedTable = table.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? table
        let urlString = "\(AppConfig.supabaseURL.absoluteString)/rest/v1/\(encodedTable)" + (query.isEmpty ? "" : "?\(query)")
        guard let url = URL(string: urlString) else { throw AppError(message: "Bad request.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(AppConfig.supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(s.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        do {
            return try await send(request)
        } catch let error as AppError where error.status == 401 {
            // Token rejected mid-flight: refresh once and retry.
            let fresh = try await refresh()
            request.setValue("Bearer \(fresh.accessToken)", forHTTPHeaderField: "Authorization")
            return try await send(request)
        }
    }

    // MARK: Transport

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await urlSession.data(for: request) }
        catch { throw AppError.network }
        guard let http = response as? HTTPURLResponse else { throw AppError.network }
        guard (200..<300).contains(http.statusCode) else {
            throw AppError(message: Self.readableError(data, status: http.statusCode), status: http.statusCode)
        }
        return data
    }

    nonisolated static func readableError(_ data: Data, status: Int) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["error_description", "msg", "message", "error"] {
                if let text = json[key] as? String, !text.isEmpty { return friendly(text) }
            }
        }
        switch status {
        case 401, 403: return "You don't have access to that. Try logging in again."
        case 404: return "That couldn't be found."
        case 429: return "Too many attempts. Wait a minute and try again."
        default: return "Something went wrong (\(status)). Try again."
        }
    }

    /// Server messages written for the website sometimes tell people to buy more games.
    /// The app never points to purchasing, so those become a neutral account status.
    nonisolated static func friendly(_ text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("invalid login credentials") { return "Incorrect email or password. Please try again." }
        if lower.contains("email not confirmed") { return "Confirm your email first. Check your inbox for the link." }
        if lower.contains("user already registered") { return "An account with this email already exists. Log in instead." }
        if lower.contains("no games left") || lower.contains("buy more") || lower.contains("paywall") {
            return "No game credits are left on this account, so this game can't be submitted right now."
        }
        if lower.contains("row-level security") { return "Your account doesn't have access to do that." }
        return text
    }
}
