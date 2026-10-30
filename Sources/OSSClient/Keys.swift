import Foundation

/// An application's API key as the server lists it (API 12): never the key.
public struct APIKeyInfo: Codable, Sendable, Equatable {
    public var application: String
    public var created: Date

    public init(application: String, created: Date) {
        self.application = application
        self.created = created
    }
}

/// A key just made: the only time it is shown.
public struct APIKeyMade: Codable, Sendable {
    public var application: String
    public var key: String

    public init(application: String, key: String) {
        self.application = application
        self.key = key
    }
}

/// `POST /v1/keys`'s body.
public struct APIKeyRequest: Codable, Sendable {
    public var application: String

    public init(application: String) {
        self.application = application
    }
}

extension OSSClient {
    /// The applications with keys (on the server's Mac, as `user`).
    public func keys() async throws -> [APIKeyInfo] { try await json("GET", "/v1/keys") }

    /// A new key for `application`, replacing one it had: shown this once.
    public func makeKey(_ application: String) async throws -> APIKeyMade {
        try await json("POST", "/v1/keys", body: APIKeyRequest(application: application))
    }

    /// `application`'s key taken away.
    public func removeKey(_ application: String) async throws {
        _ = try await send("DELETE", "/v1/keys/\(Self.encode(application))")
    }
}
