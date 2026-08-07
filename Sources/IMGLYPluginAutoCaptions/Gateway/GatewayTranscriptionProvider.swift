import Foundation

/// The default ``TranscriptionProvider``: runs the ElevenLabs Scribe v2 speech-to-text model through
/// the IMG.LY AI Gateway (`gateway.img.ly`). The gateway handles provider routing, billing, and asset
/// storage, so integrators only supply an IMG.LY API key — no separate speech-to-text account or proxy.
public struct GatewayTranscriptionProvider: TranscriptionProvider {
  public let name = "IMG.LY Gateway — ElevenLabs Scribe v2"

  private static let model = "elevenlabs/scribe-v2"

  private let client: GatewayClient

  /// Creates the provider.
  /// - Parameters:
  ///   - apiKey: An IMG.LY Gateway API key (`sk_…`), from the IMG.LY Dashboard.
  ///   - gatewayURL: The gateway base URL.
  public init(apiKey: String, gatewayURL: URL = URL(string: "https://gateway.img.ly")!) {
    client = GatewayClient(apiKey: apiKey, gatewayURL: gatewayURL)
  }

  public func transcribe(audio: Data, mimeType: String, options: TranscriptionOptions) async throws -> String {
    let audioURL = try await client.upload(audio, contentType: mimeType)
    try Task.checkCancellation()

    var input: [String: Any] = ["model": Self.model, "audio_url": audioURL]
    if let language = options.language {
      input["language_code"] = language
    }
    let completed = try await client.run(body: input)

    let words = try Self.parseWords(from: completed)
    let cues = SubtitleCue.cues(from: words, maxLineLength: options.maxLineLength, maxLines: options.maxLines)
    return SRT.serialize(cues)
  }

  /// Decodes the word-level timestamps from a `generation.completed` payload. Internal (not private) so
  /// the response-shape contract can be pinned by a unit test.
  static func parseWords(from data: Data) throws -> [TimedWord] {
    let completed = try JSONDecoder().decode(GatewayTranscript.self, from: data)
    return completed.output.first?.data.words
      // Drop only what says outright that it is not a word: a `spacing` entry is a bare " " that would
      // double the separator this joins with, and an `audio_event` puts laughter or applause on screen as
      // if it had been spoken. Keeping untyped entries matters more than it looks — the gateway may
      // normalise the field away, and requiring `type == "word"` would then discard the whole transcript.
      .filter { $0.type == nil || $0.type == Constants.wordType }
      .map { TimedWord(text: $0.text, start: $0.start, end: $0.end) } ?? []
  }

  private enum Constants {
    /// The one Scribe entry type that carries spoken text; the others are `spacing` and `audio_event`.
    static let wordType = "word"
  }
}

/// The shape of a `generation.completed` transcription payload: `output[0].data.words`.
struct GatewayTranscript: Decodable {
  let output: [Output]

  struct Output: Decodable {
    let data: TranscriptData
  }

  struct TranscriptData: Decodable {
    let words: [Word]
  }

  struct Word: Decodable {
    let text: String
    let start: Double
    let end: Double
    /// Scribe tags each entry `word`, `spacing` or `audio_event`. Optional because the gateway may
    /// normalise the field away — decoding would fail outright against such a payload otherwise.
    let type: String?
  }
}
