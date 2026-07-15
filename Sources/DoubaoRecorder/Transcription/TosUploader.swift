import Foundation
import CryptoKit

/// 音频上传协议：上传本地文件，返回公网可访问的 URL（给 ASR 的 audio.url）。
protocol AudioUploader {
    func upload(_ fileURL: URL) async throws -> (url: URL, key: String)
}

/// 火山引擎 TOS 上传器。
///
/// TOS 用 TOS4-HMAC-SHA256 签名。presigned URL 用于上传/下载；header 签名用于 copy/delete。
enum TosError: LocalizedError {
    case urlBuildFailed
    case requestFailed(String, Int)
    var errorDescription: String? {
        switch self {
        case .urlBuildFailed: return "TOS URL 构造失败"
        case .requestFailed(let what, let code): return "TOS \(what)失败，HTTP \(code)"
        }
    }
}

final class TosUploader: AudioUploader {
    let config: AppConfig
    let expires: Int

    init(config: AppConfig, expires: Int = 3600) {
        self.config = config
        self.expires = expires
    }

    // MARK: - 上传

    func upload(_ fileURL: URL) async throws -> (url: URL, key: String) {
        let key = "doubao-recorder/\(UUID().uuidString)/\(fileURL.lastPathComponent)"
        let putURL = try presignedURL(method: "PUT", key: key)
        let data = try Data(contentsOf: fileURL)
        var request = URLRequest(url: putURL)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (respData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let body = String(data: respData, encoding: .utf8) ?? ""
            FileHandle.standardError.write(Data("TOS 上传失败 HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1): \(body)\n".utf8))
            throw TosError.requestFailed("上传", (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let getURL = try presignedURL(method: "GET", key: key)
        return (getURL, key)
    }

    // MARK: - copy / delete（rename 用）

    /// 复制对象（用于改名：copy 到新 key 后 delete 旧 key）。
    func copyObject(srcKey: String, destKey: String) async throws {
        var request = try signedRequest(method: "PUT", key: destKey,
                                        extraHeaders: ["x-tos-copy-source": "/\(config.tosBucket)/\(srcKey)"])
        request.setValue("/\(config.tosBucket)/\(srcKey)", forHTTPHeaderField: "x-tos-copy-source")
        try await send(request, what: "copy")
    }

    func deleteObject(key: String) async throws {
        let request = try signedRequest(method: "DELETE", key: key)
        try await send(request, what: "delete")
    }

    private func send(_ request: URLRequest, what: String) async throws {
        let (respData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let body = String(data: respData, encoding: .utf8) ?? ""
            FileHandle.standardError.write(Data("TOS \(what)失败 HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1): \(body)\n".utf8))
            throw TosError.requestFailed(what, (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    // MARK: - TOS4 presigned URL

    private func presignedURL(method: String, key: String) throws -> URL {
        let host = "\(config.tosBucket).\(config.tosEndpoint)"
        let date = Self.amzDate()
        let shortDate = String(date.prefix(8))
        let credential = "\(config.tosAccessKey)/\(shortDate)/\(config.tosRegion)/tos/request"

        var queryItems: [(String, String)] = [
            ("X-Tos-Algorithm", "TOS4-HMAC-SHA256"),
            ("X-Tos-Credential", credential),
            ("X-Tos-Date", date),
            ("X-Tos-Expires", String(expires)),
            ("X-Tos-SignedHeaders", "host"),
        ]
        queryItems.sort { $0.0 < $1.0 }
        let canonicalQuery = queryItems
            .map { "\(Self.uriEncode($0.0))=\(Self.uriEncode($0.1))" }
            .joined(separator: "&")

        let canonicalURI = "/" + Self.uriEncode(key, encodeSlash: false)
        let canonicalHeaders = "host:\(host)\n"
        let hashedPayload = "UNSIGNED-PAYLOAD"
        let canonicalRequest = "\(method)\n\(canonicalURI)\n\(canonicalQuery)\n\(canonicalHeaders)\nhost\n\(hashedPayload)"

        let scope = "\(shortDate)/\(config.tosRegion)/tos/request"
        let canonicalHash = Self.hex(Self.sha256(Data(canonicalRequest.utf8)))
        let stringToSign = "TOS4-HMAC-SHA256\n\(date)\n\(scope)\n\(canonicalHash)"
        let signingKey = Self.signingKey(secret: config.tosSecretKey, shortDate: shortDate,
                                         region: config.tosRegion, service: "tos")
        let signature = Self.hex(Self.hmac(key: signingKey, data: Data(stringToSign.utf8)))

        let finalQuery = canonicalQuery + "&X-Tos-Signature=\(signature)"
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.percentEncodedPath = canonicalURI
        components.percentEncodedQuery = finalQuery
        guard let url = components.url else { throw TosError.urlBuildFailed }
        return url
    }

    // MARK: - TOS4 header 签名（copy/delete 用）

    private func signedRequest(method: String, key: String, extraHeaders: [String: String] = [:]) throws -> URLRequest {
        let host = "\(config.tosBucket).\(config.tosEndpoint)"
        let date = Self.amzDate()
        let shortDate = String(date.prefix(8))
        let credential = "\(config.tosAccessKey)/\(shortDate)/\(config.tosRegion)/tos/request"

        var headers: [String: String] = ["host": host, "x-tos-date": date]
        for (k, v) in extraHeaders { headers[k.lowercased()] = v }

        let sortedKeys = headers.keys.sorted()
        let canonicalHeaders = sortedKeys.map { "\($0):\(headers[$0]!)\n" }.joined()
        let signedHeaders = sortedKeys.joined(separator: ";")
        let canonicalURI = "/" + Self.uriEncode(key, encodeSlash: false)
        let payloadHash = "e3b0c44e98fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"  // sha256("")

        let canonicalRequest = "\(method)\n\(canonicalURI)\n\n\(canonicalHeaders)\n\(signedHeaders)\n\(payloadHash)"
        let scope = "\(shortDate)/\(config.tosRegion)/tos/request"
        let canonicalHash = Self.hex(Self.sha256(Data(canonicalRequest.utf8)))
        let stringToSign = "TOS4-HMAC-SHA256\n\(date)\n\(scope)\n\(canonicalHash)"
        let signingKey = Self.signingKey(secret: config.tosSecretKey, shortDate: shortDate,
                                         region: config.tosRegion, service: "tos")
        let signature = Self.hex(Self.hmac(key: signingKey, data: Data(stringToSign.utf8)))

        guard let url = URL(string: "https://\(host)\(canonicalURI)") else { throw TosError.urlBuildFailed }
        var request = URLRequest(url: url)
        request.httpMethod = method
        for k in sortedKeys { request.setValue(headers[k]!, forHTTPHeaderField: k) }
        request.setValue("TOS4-HMAC-SHA256 Credential=\(credential), SignedHeaders=\(signedHeaders), Signature=\(signature)",
                         forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: - 加密原语

    private static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    private static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }
    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    private static func signingKey(secret: String, shortDate: String, region: String, service: String) -> Data {
        let kDate = hmac(key: Data(secret.utf8), data: Data(shortDate.utf8))
        let kRegion = hmac(key: kDate, data: Data(region.utf8))
        let kService = hmac(key: kRegion, data: Data(service.utf8))
        return hmac(key: kService, data: Data("request".utf8))
    }
    private static func uriEncode(_ s: String, encodeSlash: Bool = true) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        if !encodeSlash { allowed.insert("/") }
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
    private static func amzDate() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: Date())
    }
}
