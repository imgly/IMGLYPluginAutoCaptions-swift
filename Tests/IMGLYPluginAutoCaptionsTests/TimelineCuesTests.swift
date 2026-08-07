@testable import IMGLYPluginAutoCaptions
import XCTest

/// Covers the pure timeline mapping — per-block cue offset-shift + trim-window clipping, the cross-block
/// merge-sort, and the source ranking — extracted so it can be tested without the engine.
final class TimelineCuesTests: XCTestCase {
  private func block(
    _ cues: [SubtitleCue],
    source: AutoCaptionsGenerator.Source = .video,
    timeOffset: TimeInterval,
    windowStart: TimeInterval = 0,
    windowEnd: TimeInterval = .infinity,
    speed: Double = 1,
  ) -> AutoCaptionsGenerator.TranscribedBlock {
    AutoCaptionsGenerator.TranscribedBlock(
      srt: SRT.serialize(cues), source: source, timeOffset: timeOffset,
      windowStart: windowStart, windowEnd: windowEnd, speed: speed,
    )
  }

  func testEmptyInputProducesNoCues() {
    XCTAssertEqual(AutoCaptionsGenerator.timelineCues(from: []), [])
  }

  func testZeroOffsetFullWindowIsIdentity() {
    let cues = [SubtitleCue(start: 1, end: 2, text: "a"), SubtitleCue(start: 3, end: 4, text: "b")]
    XCTAssertEqual(AutoCaptionsGenerator.timelineCues(from: [block(cues, timeOffset: 0)]), cues)
  }

  func testOffsetShiftsBothEndpoints() {
    let cues = [SubtitleCue(start: 1, end: 2.5, text: "a")]
    XCTAssertEqual(
      AutoCaptionsGenerator.timelineCues(from: [block(cues, timeOffset: 10)]),
      [SubtitleCue(start: 11, end: 12.5, text: "a")],
    )
  }

  func testTwoBlocksAreMergedAndSortedByStart() {
    // The second block sits earlier on the timeline but is passed second — the merge must re-order by
    // start (blocks transcribe in parallel and finish in nondeterministic order). They do not overlap, so
    // both keep all of their cues.
    let late = block([SubtitleCue(start: 0, end: 1, text: "late")], timeOffset: 100)
    let early = block([SubtitleCue(start: 0, end: 1, text: "early")], timeOffset: 5)
    XCTAssertEqual(AutoCaptionsGenerator.timelineCues(from: [late, early]), [
      SubtitleCue(start: 5, end: 6, text: "early"),
      SubtitleCue(start: 100, end: 101, text: "late"),
    ])
  }

  func testTrimWindowDropsOutsideCuesAndRebasesTheRest() {
    // A video clip trimmed to source [2, 5) and placed at timeline 10: the cue at source 1 is trimmed
    // away, the cue at source 6 is past the trim end, and the cue at source 3 maps to 10 + (3 - 2) = 11.
    let cues = [
      SubtitleCue(start: 1, end: 1.5, text: "before"),
      SubtitleCue(start: 3, end: 3.5, text: "inside"),
      SubtitleCue(start: 6, end: 6.5, text: "after"),
    ]
    XCTAssertEqual(
      AutoCaptionsGenerator.timelineCues(from: [block(cues, timeOffset: 10, windowStart: 2, windowEnd: 5)]),
      [SubtitleCue(start: 11, end: 11.5, text: "inside")],
    )
  }

  func testTrimWindowBoundariesAreHalfOpenAndEndIsClamped() {
    // Window [2, 5) at timeline 10. Boundary behavior, all in one test so a `<`↔`<=` or an unclamped
    // end mutation is caught:
    // - a cue starting exactly at windowStart (2) is kept, needing no clamp,
    // - a cue starting exactly at windowEnd (5) is dropped — half-open, so the window covers none of it,
    // - a cue that starts inside but runs past windowEnd has its end clamped to the window (min),
    //   so the caption never extends past the trimmed clip: end 6 -> 5, mapping to 10 + (5 - 2) = 13.
    let cues = [
      SubtitleCue(start: 2, end: 2.5, text: "at-start"),
      SubtitleCue(start: 4, end: 6, text: "overruns-end"),
      SubtitleCue(start: 5, end: 5.5, text: "at-end"),
    ]
    XCTAssertEqual(
      AutoCaptionsGenerator.timelineCues(from: [block(cues, timeOffset: 10, windowStart: 2, windowEnd: 5)]),
      [
        SubtitleCue(start: 10, end: 10.5, text: "at-start"),
        SubtitleCue(start: 12, end: 13, text: "overruns-end"),
      ],
    )
  }

  func testCuesStraddlingTheTrimWindowAreKeptAndClampedToBothEdges() {
    // Window [2, 5) at timeline 10. A cue only partly inside is still partly audible, so it survives with
    // the outside part cut off: source [1, 3) -> timeline [10, 11), source [4, 6) -> timeline [12, 13).
    let cues = [
      SubtitleCue(start: 0, end: 1, text: "fully before"),
      SubtitleCue(start: 1, end: 3, text: "straddles the in-point"),
      SubtitleCue(start: 4, end: 6, text: "straddles the out-point"),
      SubtitleCue(start: 6, end: 7, text: "fully after"),
    ]
    XCTAssertEqual(
      AutoCaptionsGenerator.timelineCues(from: [block(cues, timeOffset: 10, windowStart: 2, windowEnd: 5)]),
      [
        SubtitleCue(start: 10, end: 11, text: "straddles the in-point"),
        SubtitleCue(start: 12, end: 13, text: "straddles the out-point"),
      ],
    )
  }

  func testCuesStraddlingTheTrimWindowAreClampedInSourceTimeAtNonUnitSpeed() {
    // Window [2, 6) at 2x covers source [4, 12), placed at timeline 10. The clamp must be measured in
    // *source* seconds and only then scaled down by the speed:
    // - source [3, 6) -> [4, 6) -> timeline [10 + (4 - 4) / 2, 10 + (6 - 4) / 2) = [10, 11),
    // - source [10, 14) -> [10, 12) -> timeline [13, 14).
    let cues = [
      SubtitleCue(start: 1, end: 3, text: "fully before"),
      SubtitleCue(start: 3, end: 6, text: "straddles the in-point"),
      SubtitleCue(start: 10, end: 14, text: "straddles the out-point"),
      SubtitleCue(start: 13, end: 15, text: "fully after"),
    ]
    XCTAssertEqual(
      AutoCaptionsGenerator.timelineCues(from: [block(cues, timeOffset: 10, windowStart: 2, windowEnd: 6, speed: 2)]),
      [
        SubtitleCue(start: 10, end: 11, text: "straddles the in-point"),
        SubtitleCue(start: 13, end: 14, text: "straddles the out-point"),
      ],
    )
  }

  func testPlaybackSpeedRebasesCuesAndKeepsTheWholeClip() {
    // An untrimmed 20s clip at 2x, placed at timeline 0. The engine reports the trim window in timeline
    // seconds (20 / 2 = 10) while the transcript covers the full 20s of source, so every cue must survive
    // and land at half its source time — including the ones past source-second 10.
    let cues = [
      SubtitleCue(start: 5, end: 6, text: "first half"),
      SubtitleCue(start: 15, end: 16, text: "second half"),
    ]
    XCTAssertEqual(
      AutoCaptionsGenerator.timelineCues(from: [block(cues, timeOffset: 0, windowEnd: 10, speed: 2)]),
      [
        SubtitleCue(start: 2.5, end: 3, text: "first half"),
        SubtitleCue(start: 7.5, end: 8, text: "second half"),
      ],
    )
  }

  func testPlaybackSpeedScalesTheTrimWindowAndCueDurations() {
    // Source [4, 12) at 2x is reported as trim offset 2 and length 4, placed at timeline 10. The source-2
    // cue is before the trim in-point; the source [8, 10) cue maps to 10 + (8 - 4) / 2 = 12 and plays
    // twice as fast, so it is on screen for 1s, not 2s.
    let cues = [
      SubtitleCue(start: 2, end: 3, text: "before"),
      SubtitleCue(start: 8, end: 10, text: "inside"),
    ]
    XCTAssertEqual(
      AutoCaptionsGenerator.timelineCues(from: [block(cues, timeOffset: 10, windowStart: 2, windowEnd: 6, speed: 2)]),
      [SubtitleCue(start: 12, end: 13, text: "inside")],
    )
  }

  func testPlaybackSpeedOneLeavesCueTimingsUntouched() {
    // The control for the two cases above: at 1x the window needs no scaling and cues keep source timings.
    let cues = [
      SubtitleCue(start: 5, end: 6, text: "first half"),
      SubtitleCue(start: 15, end: 16, text: "second half"),
    ]
    XCTAssertEqual(
      AutoCaptionsGenerator.timelineCues(from: [block(cues, timeOffset: 0, windowEnd: 20, speed: 1)]),
      cues,
    )
  }

  // MARK: - Source ranking

  func testVoiceoverSuppressesTheVideoCuesItSpeaksOver() {
    // A 60s video with its own audio and a voiceover recorded over seconds 10–20, narrating for the first
    // second of it. Only the second the narrator actually speaks is taken from the video.
    let video = block([
      SubtitleCue(start: 1, end: 2, text: "video before"),
      SubtitleCue(start: 10.2, end: 10.8, text: "video under the narration"),
      SubtitleCue(start: 30, end: 31, text: "video after"),
    ], timeOffset: 0)
    let voiceover = block([
      SubtitleCue(start: 0, end: 1, text: "narration"),
    ], source: .voiceover, timeOffset: 10)

    XCTAssertEqual(AutoCaptionsGenerator.timelineCues(from: [video, voiceover]), [
      SubtitleCue(start: 1, end: 2, text: "video before"),
      SubtitleCue(start: 10, end: 11, text: "narration"),
      SubtitleCue(start: 30, end: 31, text: "video after"),
    ])
  }

  func testAVoiceoverGivesUpTheStretchesItIsSilentFor() {
    // The reported gap. A voiceover clip runs from 10 to 40 but the narrator only speaks for its first
    // second, so the video keeps everything it says in the remaining 29 — claiming the whole clip would
    // leave a long stretch with no captions at all even though only one source is talking.
    let video = block([
      SubtitleCue(start: 12, end: 13, text: "video while the narrator is silent"),
      SubtitleCue(start: 25, end: 26, text: "video later in the same clip"),
    ], timeOffset: 0)
    let voiceover = block([SubtitleCue(start: 0, end: 1, text: "narration")], source: .voiceover, timeOffset: 10)

    XCTAssertEqual(AutoCaptionsGenerator.timelineCues(from: [video, voiceover]), [
      SubtitleCue(start: 10, end: 11, text: "narration"),
      SubtitleCue(start: 12, end: 13, text: "video while the narrator is silent"),
      SubtitleCue(start: 25, end: 26, text: "video later in the same clip"),
    ])
  }

  func testAShortPauseInNarrationStaysClaimed() {
    // The beat between two sentences (1s, inside the tolerance) must not let a video caption flash in and
    // straight back out — the passage of narration is claimed as one run.
    let video = block([SubtitleCue(start: 11.2, end: 11.8, text: "video mid-pause")], timeOffset: 0)
    let voiceover = block([
      SubtitleCue(start: 0, end: 1, text: "first sentence"),
      SubtitleCue(start: 2, end: 3, text: "second sentence"),
    ], source: .voiceover, timeOffset: 10)

    XCTAssertEqual(AutoCaptionsGenerator.timelineCues(from: [video, voiceover]), [
      SubtitleCue(start: 10, end: 11, text: "first sentence"),
      SubtitleCue(start: 12, end: 13, text: "second sentence"),
    ])
  }

  func testALongSilenceBetweenNarrationIsGivenBack() {
    // The counterpart: a 9s silence is well past the tolerance, so it splits into two runs and the video
    // captions the gap between them.
    let video = block([SubtitleCue(start: 15, end: 16, text: "video in the silence")], timeOffset: 0)
    let voiceover = block([
      SubtitleCue(start: 0, end: 1, text: "first sentence"),
      SubtitleCue(start: 10, end: 11, text: "second sentence"),
    ], source: .voiceover, timeOffset: 10)

    XCTAssertEqual(AutoCaptionsGenerator.timelineCues(from: [video, voiceover]), [
      SubtitleCue(start: 10, end: 11, text: "first sentence"),
      SubtitleCue(start: 15, end: 16, text: "video in the silence"),
      SubtitleCue(start: 20, end: 21, text: "second sentence"),
    ])
  }

  func testRankingIsIndependentOfTheOrderBlocksFinishTranscribing() {
    // Blocks transcribe in parallel, so the input order is nondeterministic.
    let video = block([SubtitleCue(start: 0, end: 5, text: "video")], timeOffset: 0)
    let voiceover = block([SubtitleCue(start: 0, end: 5, text: "narration")], source: .voiceover, timeOffset: 0)
    let expected = [SubtitleCue(start: 0, end: 5, text: "narration")]

    XCTAssertEqual(AutoCaptionsGenerator.timelineCues(from: [video, voiceover]), expected)
    XCTAssertEqual(AutoCaptionsGenerator.timelineCues(from: [voiceover, video]), expected)
  }

  func testASilentVoiceoverSuppressesNothing() {
    // Otherwise recording silence over a clip would wipe that clip's captions.
    let video = block([SubtitleCue(start: 2, end: 3, text: "video")], timeOffset: 0)
    let silentVoiceover = block([], source: .voiceover, timeOffset: 0)

    XCTAssertEqual(AutoCaptionsGenerator.timelineCues(from: [video, silentVoiceover]),
                   [SubtitleCue(start: 2, end: 3, text: "video")])
  }

  func testAVideoOutranksAMusicTrackPlayingUnderIt() {
    // A song's transcribed lyrics must not displace the dialogue of the clip they play under.
    let music = block([SubtitleCue(start: 1, end: 4, text: "lyrics")], source: .audio, timeOffset: 0)
    let video = block([SubtitleCue(start: 2, end: 3, text: "dialogue")], timeOffset: 0)

    XCTAssertEqual(AutoCaptionsGenerator.timelineCues(from: [music, video]),
                   [SubtitleCue(start: 2, end: 3, text: "dialogue")])
  }

  func testSourcesThatDoNotOverlapAllKeepTheirCues() {
    // Ranking only resolves collisions.
    let voiceover = block([SubtitleCue(start: 0, end: 1, text: "narration")], source: .voiceover, timeOffset: 0)
    let video = block([SubtitleCue(start: 0, end: 1, text: "dialogue")], timeOffset: 20)

    XCTAssertEqual(AutoCaptionsGenerator.timelineCues(from: [video, voiceover]), [
      SubtitleCue(start: 0, end: 1, text: "narration"),
      SubtitleCue(start: 20, end: 21, text: "dialogue"),
    ])
  }

  func testTwoOverlappingClipsOfEqualRankAreResolvedByTimelinePosition() {
    // The earlier clip wins the moments it is speaking; the later one still captions what it says outside
    // them, both inside the overlap and past it.
    let first = block([SubtitleCue(start: 4, end: 6, text: "first")], timeOffset: 0)
    let second = block([
      SubtitleCue(start: 0, end: 1, text: "overlapped"),
      SubtitleCue(start: 2, end: 3, text: "inside the overlap but in a gap"),
      SubtitleCue(start: 7, end: 8, text: "past the first clip"),
    ], timeOffset: 5)

    XCTAssertEqual(AutoCaptionsGenerator.timelineCues(from: [second, first]), [
      SubtitleCue(start: 4, end: 6, text: "first"),
      SubtitleCue(start: 7, end: 8, text: "inside the overlap but in a gap"),
      SubtitleCue(start: 12, end: 13, text: "past the first clip"),
    ])
  }
}
