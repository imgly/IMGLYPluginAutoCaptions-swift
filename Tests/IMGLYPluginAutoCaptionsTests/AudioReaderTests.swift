@testable import IMGLYPluginAutoCaptions
import XCTest

/// Reading every source as an engine buffer used to fail for committed voiceovers (`file://`) and
/// library audio (`https://`), surfacing to the user as "no speech was detected".
final class AudioReaderTests: XCTestCase {
  private func reader(_ uri: String) -> AutoCaptionsGenerator.AudioReader? {
    URL(string: uri).map(AutoCaptionsGenerator.AudioReader.init(url:))
  }

  func testEngineBuffersAreReadFromTheBuffer() {
    XCTAssertEqual(reader("buffer://ubq/12345"), .buffer)
  }

  func testCommittedVoiceoverFilesAreReadAsResources() {
    XCTAssertEqual(reader("file:///tmp/voiceover.m4a"), .resource)
  }

  func testBundledAndRelativeSourcesAreReadAsResources() {
    XCTAssertEqual(reader("bundle://audio/beat.mp3"), .resource)
    XCTAssertEqual(reader("audio/beat.mp3"), .resource)
  }

  func testLibraryAudioIsDownloaded() {
    XCTAssertEqual(reader("https://cdn.img.ly/audio/beat.mp3"), .remote)
    XCTAssertEqual(reader("http://example.com/beat.mp3"), .remote)
  }

  func testSchemeMatchingIsCaseInsensitive() {
    XCTAssertEqual(reader("HTTPS://cdn.img.ly/audio/beat.mp3"), .remote)
    XCTAssertEqual(reader("BUFFER://ubq/12345"), .buffer)
  }
}
