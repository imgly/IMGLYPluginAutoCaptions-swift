@testable import IMGLYPluginAutoCaptions
import XCTest

/// Pins the gateway `generation.completed` response shape that `parseWords` depends on: a key drift in
/// `output[0].data.words` would otherwise silently yield no captions.
final class GatewayTranscriptionProviderTests: XCTestCase {
  func testParsesWordsFromCompletedPayload() throws {
    let json = """
    {
      "request_id": "gw_1",
      "output": [
        {
          "type": "transcript",
          "data": {
            "text": "Hello there",
            "words": [
              { "text": "Hello", "start": 0.1, "end": 0.4, "speaker": "speaker_0" },
              { "text": "there", "start": 0.5, "end": 0.9, "speaker": "speaker_0" }
            ]
          }
        }
      ]
    }
    """
    let words = try GatewayTranscriptionProvider.parseWords(from: Data(json.utf8))
    XCTAssertEqual(words.count, 2)
    XCTAssertEqual(words.first?.text, "Hello")
    XCTAssertEqual(words.first?.start, 0.1)
    XCTAssertEqual(words.first?.end, 0.4)
    XCTAssertEqual(words.last?.text, "there")
  }

  func testEmptyOutputYieldsNoWords() throws {
    let words = try GatewayTranscriptionProvider.parseWords(from: Data(#"{"output":[]}"#.utf8))
    XCTAssertTrue(words.isEmpty)
  }

  func testSpacingAndAudioEventEntriesAreDropped() throws {
    // Scribe tags every entry. A `spacing` entry is a bare " " — `SubtitleCue.cues(from:)` joins with a
    // space of its own, so keeping it would double the separator. An `audio_event` would put laughter on
    // screen as if someone had said it.
    let json = """
    {
      "output": [
        {
          "type": "transcript",
          "data": {
            "text": "Hello world",
            "words": [
              { "text": "Hello", "start": 0.0, "end": 0.5, "type": "word" },
              { "text": " ", "start": 0.5, "end": 0.5, "type": "spacing" },
              { "text": "(laughter)", "start": 0.5, "end": 0.6, "type": "audio_event" },
              { "text": "world", "start": 0.6, "end": 1.0, "type": "word" }
            ]
          }
        }
      ]
    }
    """
    let words = try GatewayTranscriptionProvider.parseWords(from: Data(json.utf8))
    XCTAssertEqual(words.map(\.text), ["Hello", "world"])
  }

  func testEntriesWithoutATypeAreKept() throws {
    // Guards the dangerous direction: the gateway may normalise `type` away, and filtering on
    // `type == "word"` would then discard every entry and return an empty transcript.
    let json = """
    {
      "output": [
        {
          "type": "transcript",
          "data": {
            "text": "Hello world",
            "words": [
              { "text": "Hello", "start": 0.0, "end": 0.5 },
              { "text": "world", "start": 0.6, "end": 1.0 }
            ]
          }
        }
      ]
    }
    """
    let words = try GatewayTranscriptionProvider.parseWords(from: Data(json.utf8))
    XCTAssertEqual(words.map(\.text), ["Hello", "world"])
  }

  func testEmptyWordsYieldsNoWords() throws {
    let json = #"{"output":[{"type":"transcript","data":{"text":"","words":[]}}]}"#
    let words = try GatewayTranscriptionProvider.parseWords(from: Data(json.utf8))
    XCTAssertTrue(words.isEmpty)
  }
}
