import Foundation
import OSSClient

#if canImport(Network)
extension Server {
    /// `/v1/keys` (API 12): the applications' keys, listed, made (shown
    /// once) and taken away, on the server's own Mac and as `user` only (the
    /// shared token or a `user` key): a key does anything an application
    /// may, so none is handed out to another computer.
    static func keysRoute(_ request: HTTPRequest, _ parts: [String], access: Access, api: API) throws -> HTTPResponse {
        guard access.application == "user" else {
            return .json(APIError(error: "keys are managed as user (the server's token)", code: "forbidden"), status: 403)
        }
        guard LocalNetworks.isThisMac(request.remoteAddress) else {
            return .json(APIError(error: "keys are managed on the server's own Mac", code: "notLocal"), status: 403)
        }
        switch (request.method, parts.count) {
        case ("GET", 2):
            return .json(api.keys.applications().map { APIKeyInfo(application: $0.application, created: $0.created) })
        case ("POST", 2):
            let asked = try JSONDecoder.oss.decode(APIKeyRequest.self, from: request.body)
            return .json(APIKeyMade(application: asked.application, key: try api.keys.make(asked.application)), status: 201)
        case ("DELETE", 3):
            let application = parts[2].removingPercentEncoding ?? parts[2]
            guard try api.keys.remove(application) else { return .error("no key for \(application)", status: 404) }
            return .json(["removed": application])
        default:
            return .error("no such endpoint: \(request.method) \(request.path)", status: 404)
        }
    }
}
#endif
