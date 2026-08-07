@testable import IMGLYPluginAutoCaptions
import XCTest

final class SRTTests: XCTestCase {
  // MARK: - Parsing

  func testParsesNumberedCues() {
    let srt = """
    1
    00:00:01,000 --> 00:00:02,500
    Hello Mark

    2
    00:00:03,000 --> 00:00:04,000
    This is a caption test
    """
    XCTAssertEqual(SRT.parse(srt), [
      SubtitleCue(start: 1, end: 2.5, text: "Hello Mark"),
      SubtitleCue(start: 3, end: 4, text: "This is a caption test"),
    ])
  }

  func testParsesCuesWithoutIndexLine() {
    let srt = """
    00:00:01,000 --> 00:00:02,000
    No index here
    """
    XCTAssertEqual(SRT.parse(srt), [SubtitleCue(start: 1, end: 2, text: "No index here")])
  }

  func testParsesMultilineCueText() {
    let srt = """
    1
    00:00:01,000 --> 00:00:02,000
    First line
    Second line
    """
    XCTAssertEqual(SRT.parse(srt).map(\.text), ["First line\nSecond line"])
  }

  func testParsesCarriageReturnLineEndings() {
    let srt = "1\r\n00:00:01,000 --> 00:00:02,000\r\nWindows file\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,000\r\nSecond"
    XCTAssertEqual(SRT.parse(srt).count, 2)
  }

  func testParsesDotMillisecondSeparator() {
    let srt = """
    00:00:01.250 --> 00:00:02.750
    VTT-style decimals
    """
    XCTAssertEqual(SRT.parse(srt), [SubtitleCue(start: 1.25, end: 2.75, text: "VTT-style decimals")])
  }

  func testParsesTimestampsWithoutHours() {
    let srt = """
    00:05,000 --> 00:06,500
    Short timestamps
    """
    XCTAssertEqual(SRT.parse(srt), [SubtitleCue(start: 5, end: 6.5, text: "Short timestamps")])
  }

  func testParsesHoursOverflow() {
    let srt = """
    01:02:03,004 --> 01:02:04,005
    Long recording
    """
    let cue = SRT.parse(srt).first
    XCTAssertEqual(cue?.start ?? 0, 3723.004, accuracy: 0.0001)
  }

  func testSkipsMalformedBlocks() {
    let srt = """
    1
    not a timestamp
    Broken

    2
    00:00:03,000 --> 00:00:04,000
    Survivor

    3
    00:00:05,000 --> garbage
    Also broken
    """
    XCTAssertEqual(SRT.parse(srt).map(\.text), ["Survivor"])
  }

  func testSkipsCuesWithoutText() {
    let srt = """
    1
    00:00:01,000 --> 00:00:02,000

    2
    00:00:03,000 --> 00:00:04,000
    Has text
    """
    XCTAssertEqual(SRT.parse(srt).map(\.text), ["Has text"])
  }

  func testParsesEmptyStringToNoCues() {
    XCTAssertEqual(SRT.parse(""), [])
  }

  // MARK: - Serialization

  func testSerializesAndRenumbersCues() {
    let cues = [
      SubtitleCue(start: 1, end: 2.5, text: "First"),
      SubtitleCue(start: 3, end: 4, text: "Second\nline"),
    ]
    XCTAssertEqual(SRT.serialize(cues), """
    1
    00:00:01,000 --> 00:00:02,500
    First

    2
    00:00:03,000 --> 00:00:04,000
    Second
    line
    """)
  }

  func testRoundTripPreservesCues() {
    let cues = [
      SubtitleCue(start: 0.079, end: 2.18, text: "Hello Mark, this is a caption test."),
      SubtitleCue(start: 3723.004, end: 3725.999, text: "One hour in"),
    ]
    XCTAssertEqual(SRT.parse(SRT.serialize(cues)), cues)
  }

  // MARK: - Timestamps

  func testFormatsTimestamps() {
    XCTAssertEqual(SRT.timestamp(0), "00:00:00,000")
    XCTAssertEqual(SRT.timestamp(1.5), "00:00:01,500")
    XCTAssertEqual(SRT.timestamp(61.001), "00:01:01,001")
    XCTAssertEqual(SRT.timestamp(3723.004), "01:02:03,004")
  }

  func testFormatsTimestampRoundingMilliseconds() {
    XCTAssertEqual(SRT.timestamp(0.9995), "00:00:01,000")
  }

  func testRejectsMalformedTimestamps() {
    XCTAssertNil(SRT.seconds(fromTimestamp: "garbage"))
    XCTAssertNil(SRT.seconds(fromTimestamp: "00"))
    XCTAssertNil(SRT.seconds(fromTimestamp: "aa:bb:cc,ddd"))
    XCTAssertNil(SRT.seconds(fromTimestamp: ""))
  }
}
