import Foundation

/// Options that control how audio is transcribed and formatted into subtitles.
public struct TranscriptionOptions: Sendable {
  /// The BCP-47 language code of the spoken audio, e.g. "en", "de", "pt". `nil` lets the provider
  /// detect the language automatically.
  public var language: String?

  /// The maximum number of characters a subtitle line may hold before the next word starts a new line.
  public var maxLineLength: Int

  /// The maximum number of lines a single subtitle cue may span before the next words start a new cue.
  public var maxLines: Int

  /// Creates transcription options.
  /// - Parameters:
  ///   - language: The BCP-47 language code of the spoken audio. `nil` auto-detects.
  ///   - maxLineLength: The maximum number of characters per subtitle line.
  ///   - maxLines: The maximum number of lines per subtitle cue.
  public init(language: String? = nil, maxLineLength: Int = 37, maxLines: Int = 1) {
    self.language = language
    self.maxLineLength = maxLineLength
    self.maxLines = maxLines
  }
}

/// A speech-to-text backend that turns audio into SRT subtitles.
///
/// Implement this protocol to plug any transcription service into ``AutoCaptionsPlugin``; the built-in
/// ``GatewayTranscriptionProvider`` runs ElevenLabs Scribe v2 through the IMG.LY AI Gateway.
public protocol TranscriptionProvider: Sendable {
  /// A human-readable name, included in the generation-failure log to identify which provider failed.
  var name: String { get }

  /// Transcribes audio into SRT subtitle text.
  ///
  /// - Parameters:
  ///   - audio: The audio data to transcribe.
  ///   - mimeType: The MIME type of `audio`, i.e. the source track's own type — commonly `audio/mp4`
  ///     (AAC, from a video's extracted track), `audio/wav`, or `audio/mpeg` (a standalone audio block).
  ///   - options: Language and subtitle formatting options.
  /// - Returns: An SRT-formatted string with timings relative to the start of the audio. Return an
  ///   empty string when no speech was detected.
  /// - Throws: Any transport or service error; it surfaces as a generation-failure alert in the
  ///   editor. The surrounding task is cancelled when the user taps Cancel, so implementations
  ///   should stay cooperatively cancellable (`URLSession`'s async APIs already are).
  func transcribe(audio: Data, mimeType: String, options: TranscriptionOptions) async throws -> String
}
