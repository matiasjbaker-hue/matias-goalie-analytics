import Foundation

/// The website's serverless endpoints (`api/` in the repo). Each takes the caller's
/// Supabase access token in the JSON body and checks it server-side.
enum APIClient {
    struct StartUpload: Decodable {
        struct PartURL: Decodable { let partNumber: Int; let url: URL }
        let key: String
        let uploadId: String
        let partSize: Int
        let partUrls: [PartURL]
    }

    struct Part: Codable, Hashable { let PartNumber: Int; let ETag: String }

    static func startUpload(fileName: String, size: Int64, contentType: String, ownerId: String?) async throws -> StartUpload {
        var body: [String: AnyEncodable] = [
            "fileName": AnyEncodable(fileName),
            "fileSizeBytes": AnyEncodable(size),
            "contentType": AnyEncodable(contentType),
        ]
        if let ownerId { body["ownerId"] = AnyEncodable(ownerId) }
        return try await post("api/video/r2-start-upload", body)
    }

    static func completeUpload(key: String, uploadId: String, parts: [Part], expectedSize: Int64) async throws {
        struct Done: Decodable { let key: String? }
        let _: Done = try await post("api/video/r2-complete-upload", [
            "key": AnyEncodable(key),
            "uploadId": AnyEncodable(uploadId),
            "parts": AnyEncodable(parts),
            "expectedSize": AnyEncodable(expectedSize),
        ])
    }

    static func abortUpload(key: String, uploadId: String) async {
        struct Done: Decodable { let aborted: Bool? }
        let _: Done? = try? await post("api/video/r2-complete-upload", [
            "key": AnyEncodable(key), "uploadId": AnyEncodable(uploadId), "abort": AnyEncodable(true),
        ])
    }

    static func sendFilmLink(url: String, note: String?, game: String, jerseyColor: String?) async throws {
        struct Done: Decodable { let ok: Bool? }
        var body: [String: AnyEncodable] = ["url": AnyEncodable(url), "game": AnyEncodable(game)]
        if let note, !note.isEmpty { body["note"] = AnyEncodable(note) }
        if let jerseyColor, !jerseyColor.isEmpty { body["jerseyColor"] = AnyEncodable(jerseyColor) }
        let _: Done = try await post("api/admin/film-link", body)
    }

    /// Any non-admin user may delete their own account (see api/_lib/admin-delete-account.js).
    static func deleteAccount(userId: String) async throws {
        struct Done: Decodable { let ok: Bool? }
        let _: Done = try await post("api/admin/delete-account", ["targetId": AnyEncodable(userId)])
    }

    // MARK: Transport

    private static func post<T: Decodable>(_ path: String, _ fields: [String: AnyEncodable]) async throws -> T {
        let session = try await SupabaseClient.shared.validSession()
        var body = fields
        body["accessToken"] = AnyEncodable(session.accessToken)
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { throw AppError.network }
        guard let http = response as? HTTPURLResponse else { throw AppError.network }
        guard (200..<300).contains(http.statusCode) else {
            throw AppError(message: SupabaseClient.readableError(data, status: http.statusCode), status: http.statusCode)
        }
        if data.isEmpty, let empty = try? JSONDecoder().decode(T.self, from: Data("{}".utf8)) { return empty }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch {
            if let empty = try? JSONDecoder().decode(T.self, from: Data("{}".utf8)) { return empty }
            throw AppError(message: "Unexpected reply from the server.")
        }
    }
}

/// Type-erased Encodable for small heterogeneous JSON bodies.
struct AnyEncodable: Encodable {
    private let encodeFn: (Encoder) throws -> Void
    init<T: Encodable>(_ value: T) { encodeFn = value.encode }
    func encode(to encoder: Encoder) throws { try encodeFn(encoder) }
}
