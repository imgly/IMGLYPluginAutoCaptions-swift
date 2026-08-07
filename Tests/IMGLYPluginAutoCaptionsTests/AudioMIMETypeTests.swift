@testable import IMGLYPluginAutoCaptions
import XCTest

/// The MIME type reaches the gateway from servers we do not control, and the gateway only accepts the IANA
/// list. `studio.staticimgly.com` serves `.mp3` as `audio/mp3`, which it rejects with HTTP 400.
final class AudioMIMETypeTests: XCTestCase {
  private func canonical(_ mimeType: String?) -> String {
    AutoCaptionsGenerator.canonicalAudioMIMEType(mimeType)
  }

  func testUnregisteredMP3SpellingsBecomeAudioMPEG() {
    for spelling in ["audio/mp3", "audio/x-mp3", "audio/mpeg3", "audio/x-mpeg3"] {
      XCTAssertEqual(canonical(spelling), "audio/mpeg", spelling)
    }
  }

  func testUnregisteredM4ASpellingsBecomeAudioMP4() {
    for spelling in ["audio/m4a", "audio/x-m4a"] {
      XCTAssertEqual(canonical(spelling), "audio/mp4", spelling)
    }
  }

  func testRegisteredTypesPassThrough() {
    for registered in ["audio/mpeg", "audio/mp4", "audio/wav", "audio/ogg", "audio/flac"] {
      XCTAssertEqual(canonical(registered), registered)
    }
  }

  func testParametersAreStrippedAndCaseIsNormalized() {
    XCTAssertEqual(canonical("audio/mp3; charset=binary"), "audio/mpeg")
    XCTAssertEqual(canonical("AUDIO/MP3"), "audio/mpeg")
    XCTAssertEqual(canonical("  audio/mpeg  "), "audio/mpeg")
  }

  func testMissingTypeFallsBackToAudioMPEG() {
    XCTAssertEqual(canonical(nil), "audio/mpeg")
    XCTAssertEqual(canonical(""), "audio/mpeg")
  }
}
