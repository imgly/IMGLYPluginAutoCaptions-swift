@testable import IMGLYPluginAutoCaptions
import XCTest

/// Verifies that timed words group into subtitle cues according to the line-length and line-count
/// limits.
final class WordsToCuesTests: XCTestCase {
  private func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TimedWord {
    TimedWord(text: text, start: start, end: end)
  }

  func testEmptyWordsProduceNoCues() {
    XCTAssertEqual(SubtitleCue.cues(from: [], maxLineLength: 37, maxLines: 1), [])
  }

  func testSingleShortLineBecomesOneCue() {
    let cues = SubtitleCue.cues(
      from: [word("Hello", 0.0, 0.4), word("Mark", 0.5, 0.9)],
      maxLineLength: 37,
      maxLines: 1,
    )
    XCTAssertEqual(cues, [SubtitleCue(start: 0.0, end: 0.9, text: "Hello Mark")])
  }

  func testCueTimestampsSpanFirstToLastWord() {
    let cues = SubtitleCue.cues(
      from: [word("one", 1.0, 1.2), word("two", 1.3, 1.5), word("three", 1.6, 2.0)],
      maxLineLength: 37,
      maxLines: 1,
    )
    XCTAssertEqual(cues.first?.start, 1.0)
    XCTAssertEqual(cues.first?.end, 2.0)
  }

  func testSplitsIntoNewCueWhenLineIsFullAndMaxLinesIsOne() {
    // "aaaa bbbb" (9 chars) fits; adding "cccc" would exceed 10 — with maxLines 1 the cue is full.
    let cues = SubtitleCue.cues(
      from: [word("aaaa", 0, 1), word("bbbb", 1, 2), word("cccc", 2, 3)],
      maxLineLength: 10,
      maxLines: 1,
    )
    XCTAssertEqual(cues, [
      SubtitleCue(start: 0, end: 2, text: "aaaa bbbb"),
      SubtitleCue(start: 2, end: 3, text: "cccc"),
    ])
  }

  func testWrapsIntoSecondLineWhenMaxLinesIsTwo() {
    let cues = SubtitleCue.cues(
      from: [word("aaaa", 0, 1), word("bbbb", 1, 2), word("cccc", 2, 3)],
      maxLineLength: 10,
      maxLines: 2,
    )
    XCTAssertEqual(cues, [SubtitleCue(start: 0, end: 3, text: "aaaa bbbb\ncccc")])
  }

  func testFullTwoLineCueFlushesBeforeNextWord() {
    let cues = SubtitleCue.cues(
      from: [word("aaaa", 0, 1), word("bbbb", 1, 2), word("cccc", 2, 3), word("dddd", 3, 4), word("eeee", 4, 5)],
      maxLineLength: 10,
      maxLines: 2,
    )
    XCTAssertEqual(cues, [
      SubtitleCue(start: 0, end: 4, text: "aaaa bbbb\ncccc dddd"),
      SubtitleCue(start: 4, end: 5, text: "eeee"),
    ])
  }

  func testOverlongSingleWordGetsItsOwnLine() {
    let cues = SubtitleCue.cues(
      from: [word("aa", 0, 1), word("unpronounceable", 1, 2)],
      maxLineLength: 10,
      maxLines: 1,
    )
    XCTAssertEqual(cues, [
      SubtitleCue(start: 0, end: 1, text: "aa"),
      SubtitleCue(start: 1, end: 2, text: "unpronounceable"),
    ])
  }

  func testLineLengthMeasuredInUTF16CodeUnits() {
    // "ab 😀c" is 6 UTF-16 code units but only 5 graphemes, so at maxLineLength 5 the UTF-16 measurement
    // wraps it into a second cue where Swift's grapheme `.count` would not.
    let cues = SubtitleCue.cues(
      from: [word("ab", 0, 1), word("😀c", 1, 2)],
      maxLineLength: 5,
      maxLines: 1,
    )
    XCTAssertEqual(cues, [
      SubtitleCue(start: 0, end: 1, text: "ab"),
      SubtitleCue(start: 1, end: 2, text: "😀c"),
    ])
  }

  func testCandidateExactlyAtMaxLineLengthStaysOnOneLine() {
    // "aaaa bbbb" is exactly 9 UTF-16 code units; with the inclusive `>` fit it stays on one line at
    // maxLineLength 9 — pins the boundary a `>`→`>=` mutation would break.
    let cues = SubtitleCue.cues(
      from: [word("aaaa", 0, 1), word("bbbb", 1, 2)],
      maxLineLength: 9,
      maxLines: 1,
    )
    XCTAssertEqual(cues, [SubtitleCue(start: 0, end: 2, text: "aaaa bbbb")])
  }

  func testDefaultLimits() {
    // 37 chars per line, one line per cue — the `TranscriptionOptions` defaults.
    let words = (0 ..< 20).map { word("word\($0)", TimeInterval($0), TimeInterval($0) + 0.5) }
    let cues = SubtitleCue.cues(from: words, maxLineLength: 37, maxLines: 1)
    XCTAssertTrue(cues.allSatisfy { cue in
      cue.text.components(separatedBy: "\n").allSatisfy { $0.count <= 37 }
    })
    // No word is lost or duplicated by the grouping.
    XCTAssertEqual(cues.flatMap { $0.text.split(whereSeparator: \.isWhitespace) }.count, 20)
  }
}
