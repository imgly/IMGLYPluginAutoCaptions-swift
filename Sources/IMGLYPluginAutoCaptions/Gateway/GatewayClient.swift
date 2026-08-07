import Foundation

/// A minimal `URLSession` client for the IMG.LY AI Gateway (`gateway.img.ly`): upload an input asset,
/// run a model, and read the SSE result. Auth is a Bearer `sk_…` API key.
struct GatewayClient: Sendable {
  let apiKey: String
  let gatewayURL: URL

  /// Speech-to-text can take a while for long recordings, so allow a generous idle timeout.
  private static let requestTimeout: TimeInterval = 600

  enum ClientError: LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case generationFailed(String)
    case noResult

    var errorDescription: String? {
      switch self {
      case .invalidResponse:
        "The gateway returned an invalid response."
      case let .httpError(statusCode, body):
        "The gateway returned HTTP \(statusCode): \(body)"
      case let .generationFailed(message):
        "Transcription failed: \(message)"
      case .noResult:
        "The gateway stream ended without a result."
      }
    }
  }

  /// Uploads bytes to the gateway and returns the resulting asset URL: a presigned upload URL is
  /// requested first, then the bytes are PUT to it directly (no auth on the PUT).
  func upload(_ data: Data, contentType: String) async throws -> String {
    var request = authorizedRequest(path: "v1/uploads")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["content_type": contentType])

    let (metadataData, response) = try await URLSession.shared.data(for: request)
    try Self.validate(response, body: metadataData)
    let metadata = try JSONDecoder().decode(UploadMetadata.self, from: metadataData)

    guard let uploadURL = URL(string: metadata.uploadURL) else { throw ClientError.invalidResponse }
    var put = URLRequest(url: uploadURL, timeoutInterval: Self.requestTimeout)
    put.httpMethod = "PUT"
    put.setValue(contentType, forHTTPHeaderField: "Content-Type")
    let (body, putResponse) = try await URLSession.shared.upload(for: put, from: data)
    try Self.validate(putResponse, body: body)
    return metadata.assetURL
  }

  /// Runs a model via `POST /v1/responses` and returns the `data` payload of the `generation.completed`
  /// SSE event. Throws on `generation.failed` or a stream that ends without completing.
  func run(body: [String: Any]) async throws -> Data {
    var request = authorizedRequest(path: "v1/responses")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
    guard (200 ..< 300).contains(http.statusCode) else {
      throw ClientError.httpError(statusCode: http.statusCode, body: await Self.readBounded(bytes))
    }

    var event = ""
    for try await line in bytes.lines {
      try Task.checkCancellation()
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty || trimmed.hasPrefix(":") {
        continue
      } // blank line / SSE comment
      if trimmed.hasPrefix("event:") {
        event = String(trimmed.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
        continue
      }
      guard trimmed.hasPrefix("data:") else { continue }
      let payload = String(trimmed.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
      guard let data = payload.data(using: .utf8) else { continue }
      switch event {
      case "generation.completed": return data
      case "generation.failed": throw ClientError.generationFailed(Self.failureMessage(data))
      default: break
      }
      // Reset after each consumed data line so a later `data:` without its own `event:` cannot inherit
      // this event type.
      event = ""
    }
    throw ClientError.noResult
  }

  /// Builds a `POST` request to a gateway path with the Bearer auth header set.
  private func authorizedRequest(path: String) -> URLRequest {
    var request = URLRequest(url: gatewayURL.appendingPathComponent(path), timeoutInterval: Self.requestTimeout)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    return request
  }

  private static func validate(_ response: URLResponse, body: Data) throws {
    guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
    guard (200 ..< 300).contains(http.statusCode) else {
      // Bound the surfaced error body like the SSE path's `readBounded`, so a large response can't
      // balloon the error message.
      throw ClientError.httpError(
        statusCode: http.statusCode, body: String(bytes: body.prefix(4096), encoding: .utf8) ?? "",
      )
    }
  }

  private static func failureMessage(_ data: Data) -> String {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let error = object["error"] as? [String: Any],
          let message = error["message"] as? String else {
      return "Generation failed"
    }
    return message
  }

  private static func readBounded(_ bytes: URLSession.AsyncBytes) async -> String {
    var data = Data()
    do {
      for try await byte in bytes {
        data.append(byte)
        if data.count >= 4096 {
          break
        }
      }
    } catch {
      // Best-effort: a truncated or failed error-body read is not worth surfacing over the HTTP status
      // it accompanies.
    }
    return String(data: data, encoding: .utf8) ?? ""
  }
}

/// The `/v1/uploads` response: a presigned `upload_url` to PUT bytes to, and the `asset_url` to
/// reference the uploaded asset in a subsequent run.
private struct UploadMetadata: Decodable {
  let uploadURL: String
  let assetURL: String

  enum CodingKeys: String, CodingKey {
    case uploadURL = "upload_url"
    case assetURL = "asset_url"
  }
}
