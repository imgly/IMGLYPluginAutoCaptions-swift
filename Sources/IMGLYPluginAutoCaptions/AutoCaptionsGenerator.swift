import Foundation
import IMGLYEngine
import OSLog

extension Logger {
  /// Subsystem-scoped logger for the auto-captions plugin.
  static let autoCaptions = Logger(subsystem: "ly.img.plugin.autoCaptions", category: "AutoCaptions")
}

/// A half-open stretch of the page timeline, in seconds. A degenerate span intersects nothing, so a block
/// whose duration the engine cannot report claims nothing.
private struct TimeSpan {
  let start: TimeInterval
  let end: TimeInterval

  func intersects(_ other: TimeSpan) -> Bool {
    start < other.end && other.start < end
  }
}

/// A pause this short inside one source's speech stays claimed by that source. Long enough to cover the beat
/// between two sentences, short enough that a real silence is handed back to whatever else is audible.
private let maxClaimedPause: TimeInterval = 1.5

/// Orchestrates the generate flow: find the scene's audible blocks, export each block's audio,
/// transcribe them via the provider (in parallel), map each block's cues onto the page timeline, and
/// merge everything sorted into a single SRT file for the editor to import.
@MainActor
enum AutoCaptionsGenerator {
  /// Which source a block's audio counts as. Two sources audible at the same instant cannot both caption
  /// it, so the declaration order ranks them — see ``timelineCues(from:)``. A voiceover is deliberate
  /// narration and outranks the video it is layered over; music and sound effects are the least likely to
  /// carry the speech the user wants captioned.
  enum Source: Int, Sendable {
    case voiceover
    case video
    case audio
  }

  /// One audible block's exported audio, its MIME type, and the mapping needed to place its cues on the
  /// page timeline.
  private struct BlockAudio: Sendable {
    /// The block's audio staged on disk. A file rather than `Data` because a scene's audible content is
    /// unbounded — several clips, or one long recording, would otherwise all be resident at once.
    let url: URL
    let mimeType: String
    let source: Source
    /// The block's position on the page timeline.
    let timeOffset: TimeInterval
    /// The played (trimmed) window as the engine reports it, in *timeline* seconds. Both branches read the
    /// whole source track, so the window is the block's (audio) or fill's (video) trim range.
    let windowStart: TimeInterval
    let windowEnd: TimeInterval
    /// The block's playback speed multiplier.
    let speed: Double
  }

  /// A block's raw transcript plus the mapping needed to place its cues on the page timeline. Pure data,
  /// so ``timelineCues(from:)`` can be unit-tested without the engine.
  struct TranscribedBlock: Sendable {
    let srt: String
    let source: Source
    let timeOffset: TimeInterval
    let windowStart: TimeInterval
    let windowEnd: TimeInterval
    let speed: Double
  }

  /// How an audio source's bytes have to be read — no single engine API covers every source an audio
  /// block can have.
  enum AudioReader: Sendable, Equatable {
    /// `getBufferData`: a video's muxed track, or a voiceover that is still being recorded.
    case buffer
    /// `getResourceData`: anything the engine resolves locally, most importantly a committed voiceover,
    /// whose `audio/fileURI` is a `file://` cache URL.
    case resource
    /// A network fetch for library audio — `getResourceData` rejects `http(s)` sources outright.
    case remote

    init(url: URL) {
      switch url.scheme?.lowercased() {
      case "buffer": self = .buffer
      case "http", "https": self = .remote
      default: self = .resource
      }
    }
  }

  private enum AudioSourceError: LocalizedError {
    case httpError(url: URL, statusCode: Int)

    var errorDescription: String? {
      switch self {
      case let .httpError(url, statusCode):
        "Downloading audio from \(url.absoluteString) returned HTTP \(statusCode)."
      }
    }
  }

  /// A heuristic, not a contract: the kind the editor stamps on a recorded voiceover. An audio block with
  /// any other kind is still transcribed, it just doesn't get the narration ranking.
  private static let voiceoverKind = "voiceover"

  /// Generates a temporary SRT file with cues for all audible content in the scene.
  ///
  /// Every block's audio is staged in a directory of its own, deleted however the run ends — including
  /// the cancellation the sheet triggers. The SRT is written outside that directory, so the cleanup does
  /// not take the file the editor is about to import.
  ///
  /// - Returns: The URL of the SRT file, or `nil` when there is nothing audible or nothing was
  ///   transcribed.
  /// - Throws: The first underlying error when every block fails to export or transcribe.
  static func generateCaptionsFile(
    engine: Engine,
    provider: any TranscriptionProvider,
    options: TranscriptionOptions,
  ) async throws -> URL? {
    let staging = FileManager.default.temporaryDirectory
      .appendingPathComponent("imgly-auto-captions-\(UUID().uuidString)", isDirectory: true)
    // Synchronous, so cancellation cannot skip it the way an `await` in a cancelled task would.
    defer { try? FileManager.default.removeItem(at: staging) }

    let audios = try await exportAudibleBlocks(engine: engine, staging: staging)
    guard !audios.isEmpty else { return nil }

    let cues = try await transcribe(audios, provider: provider, options: options)
    guard !cues.isEmpty else { return nil }

    return try await writeSRT(cues)
  }

  /// Serialises the cues and writes them to a temporary file.
  ///
  /// This type is `@MainActor` because it drives the engine, but serialising a long transcript and
  /// committing it to disk are neither engine work nor UI work, and `write(to:options:.atomic)` blocks
  /// its thread until the filesystem is done — a temp-file write plus a rename.
  ///
  /// `@concurrent` rather than `nonisolated`: both leave the main actor today, but SE-0461 makes a
  /// `nonisolated async` function run on the caller's actor in Swift 7, which would silently put this
  /// work back on main with nothing failing to signal it.
  @concurrent
  private static func writeSRT(_ cues: [SubtitleCue]) async throws -> URL {
    let srt = SRT.serialize(cues) // already merged and sorted by `timelineCues`
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("srt")
    try Data(srt.utf8).write(to: url, options: [.atomic])
    return url
  }

  // MARK: - Timeline mapping (pure)

  /// Maps every block's transcript onto the shared page timeline and merges them into one time-ordered
  /// cue list.
  ///
  /// The captions land in a single track, so sources audible at the same instant must be resolved rather
  /// than concatenated. Blocks are walked best-source-first (see ``Source``), each claiming the stretches it
  /// is *speaking* for (see ``speechEnvelope(of:)``), and a lower-ranked block's cues inside an existing
  /// claim are dropped. A block that transcribes to nothing claims nothing, so a silent voiceover never
  /// suppresses the video under it.
  ///
  /// A source claims what it says, not the clip it says it in: a 30-second voiceover holding 5 seconds of
  /// narration leaves the other 25 to the video underneath, instead of silencing it throughout.
  ///
  /// Transcribing the *mixed* page audio instead is not reachable here: the engine's only mixer is the
  /// page-audio encoder this plugin had to move off (IOS-897).
  nonisolated static func timelineCues(from blocks: [TranscribedBlock]) -> [SubtitleCue] {
    var merged: [SubtitleCue] = []
    var claimed: [TimeSpan] = []
    for block in blocks.sorted(by: { ($0.source.rawValue, $0.timeOffset) < ($1.source.rawValue, $1.timeOffset) }) {
      let cues = timelineCues(of: block).filter { cue in
        !claimed.contains { $0.intersects(TimeSpan(start: cue.start, end: cue.end)) }
      }
      guard !cues.isEmpty else { continue }
      merged += cues
      claimed += speechEnvelope(of: cues)
    }
    return merged.sorted { $0.start < $1.start }
  }

  /// The stretches a source is actually speaking for, with pauses up to ``maxClaimedPause`` absorbed.
  ///
  /// The two extremes are both wrong. Claiming the block's whole length silences the video under a voiceover
  /// for the entire clip, however little of it the narrator fills — the reported gap. Claiming the bare cues
  /// overcorrects: the beat between two sentences would let a video caption flash in and straight back out.
  /// Merging across a short pause keeps a continuous passage of narration whole while handing back a silence
  /// long enough to be worth captioning.
  private nonisolated static func speechEnvelope(of cues: [SubtitleCue]) -> [TimeSpan] {
    cues
      .map { TimeSpan(start: $0.start, end: $0.end) }
      .sorted { $0.start < $1.start }
      .reduce(into: [TimeSpan]()) { envelope, span in
        guard let previous = envelope.last, span.start - previous.end <= maxClaimedPause else {
          envelope.append(span)
          return
        }
        // Cues can nest or straddle, so the run keeps whichever end reaches furthest.
        envelope[envelope.index(before: envelope.endIndex)] =
          TimeSpan(start: previous.start, end: max(previous.end, span.end))
      }
  }

  /// Maps one block's transcript onto the page timeline. A cue that straddles a window edge is clamped
  /// rather than dropped: the trimmed-away half is silent, but the rest is still spoken.
  ///
  /// Cue timestamps are *source* seconds — the transcript is made from the untouched source bytes, which
  /// know nothing of the playback speed — while the trim window is *timeline* seconds. So the window is
  /// scaled up into the source time base to select and clamp cues, and a survivor is scaled back down to
  /// be placed and to get the on-screen length it is actually spoken in.
  private nonisolated static func timelineCues(of block: TranscribedBlock) -> [SubtitleCue] {
    let windowStart = block.windowStart * block.speed
    let windowEnd = block.windowEnd * block.speed
    let onTimeline = { (sourceTime: TimeInterval) in
      block.timeOffset + (sourceTime - windowStart) / block.speed
    }
    return SRT.parse(block.srt).compactMap { cue in
      guard cue.end > windowStart, cue.start < windowEnd else { return nil }
      return SubtitleCue(start: onTimeline(max(cue.start, windowStart)),
                         end: onTimeline(min(cue.end, windowEnd)), text: cue.text)
    }
  }

  // MARK: - Audio export (sequential, engine-bound)

  private static func exportAudibleBlocks(engine: Engine, staging: URL) async throws -> [BlockAudio] {
    var audios: [BlockAudio] = []
    var firstError: (any Error)?
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    for (index, candidate) in audibleCandidates(engine: engine).enumerated() {
      try Task.checkCancellation()
      do {
        if let audio = try await exportAudio(from: candidate.id, source: candidate.source, engine: engine,
                                             to: staging.appendingPathComponent("audio-\(index)")) {
          audios.append(audio)
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // A single block failing to load or export must not sink the others — only an all-failed run
        // surfaces an error.
        Logger.autoCaptions.error("Audio export failed for a block: \(error.localizedDescription, privacy: .public)")
        if firstError == nil {
          firstError = error
        }
      }
    }
    if audios.isEmpty, let firstError {
      throw firstError
    }
    return audios
  }

  /// Every block on the current page that could carry audible content, tagged with the source it counts
  /// as. Audio is found by *type* because its kind varies (the editor stamps voiceovers `voiceover`,
  /// integrators use their own); video only by kind, since it shares the `graphic` type with images.
  ///
  /// Both queries search the whole scene, so other pages' blocks are filtered out: the SRT is imported
  /// into the current page, and their cues would land there at another page's local time offsets.
  private static func audibleCandidates(engine: Engine) -> [(id: DesignBlockID, source: Source)] {
    guard let page = try? engine.scene.getCurrentPage() else { return [] }
    let audio = ((try? engine.block.find(byType: .audio)) ?? []).map { id in
      (id: id, source: (try? engine.block.getKind(id)) == voiceoverKind ? Source.voiceover : .audio)
    }
    let video = ((try? engine.block.find(byKind: "video")) ?? []).map { (id: $0, source: Source.video) }
    return (audio + video).filter { isDescendant($0.id, of: page, engine: engine) }
  }

  /// Whether a block sits anywhere below `page` — directly, or nested in one of its tracks.
  private static func isDescendant(_ block: DesignBlockID, of page: DesignBlockID, engine: Engine) -> Bool {
    var current = block
    while let parent = try? engine.block.getParent(current) {
      if parent == page {
        return true
      }
      current = parent
    }
    return false
  }

  /// Exports a block's audio, or returns `nil` when it has nothing audible — muted, silenced (volume 0),
  /// or a video without an audio track.
  ///
  /// Audibility (`isMuted`/`getVolume`) is a design property that needs no loaded resource, so silent
  /// blocks are dropped *before* the (potentially expensive) `forceLoadAVResource`. The audibility id
  /// matches the timeline's `trimmableID`: the fill for a video, the block itself for audio.
  private static func exportAudio(
    from block: DesignBlockID,
    source: Source,
    engine: Engine,
    to destination: URL,
  ) async throws -> BlockAudio? {
    if source == .video {
      return try await exportVideoAudio(from: block, engine: engine, to: destination)
    }

    // Read the source directly: `exportAudio` routes through the page-audio encoder, which strips the page
    // mid-export and crashes the live editor (IOS-897). Same reason the video branch never exports either.
    guard try isAudible(block, engine: engine) else { return nil }
    try await engine.block.forceLoadAVResource(block)
    guard let url = try audioFileURL(of: block, engine: engine),
          try await stageAudio(at: url, engine: engine, to: destination) else { return nil }
    let mimeType = canonicalAudioMIMEType(try? await engine.editor.getMIMEType(url: url))
    return blockAudio(destination, mimeType: mimeType, source: source, of: block, trimmedBy: block,
                      engine: engine)
  }

  /// The registered name for an audio MIME type, since the value reaches us from servers we do not control
  /// and the gateway only accepts the IANA list — `audio/mp3` is a common unregistered spelling of
  /// `audio/mpeg` and is rejected outright.
  nonisolated static func canonicalAudioMIMEType(_ mimeType: String?) -> String {
    let type = (mimeType ?? "").split(separator: ";").first?
      .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
    return switch type {
    case "": "audio/mpeg"
    case "audio/mp3", "audio/x-mp3", "audio/mpeg3", "audio/x-mpeg3": "audio/mpeg"
    case "audio/m4a", "audio/x-m4a": "audio/mp4"
    default: type
    }
  }

  /// Extracts a video's audio track into a detached audio block and reads that block's buffer. A video's
  /// audio-track count can only be probed once the resource is loaded, so that check follows the load.
  ///
  /// Destroying the block does *not* release the `BufferRegistry` buffer the extraction minted — only
  /// `destroyBuffer` does — so both are freed on every path out, throws and cancellation included.
  private static func exportVideoAudio(
    from block: DesignBlockID,
    engine: Engine,
    to destination: URL,
  ) async throws -> BlockAudio? {
    guard try engine.block.supportsFill(block) else { return nil }
    let fill = try engine.block.getFill(block)
    guard try isAudible(fill, engine: engine) else { return nil }
    try await engine.block.forceLoadAVResource(fill)
    guard try engine.block.getAudioTrackCountFromVideo(fill) > 0 else { return nil }

    let audioBlock = try engine.block.createAudioFromVideo(fill, trackIndex: 0)
    let bufferURL = try? audioFileURL(of: audioBlock, engine: engine)
    defer {
      try? engine.block.destroy(audioBlock)
      // Scheme check: only a minted buffer may be destroyed, never a URL resolving to a user's own file.
      if let bufferURL, AudioReader(url: bufferURL) == .buffer {
        try? engine.editor.destroyBuffer(url: bufferURL)
      }
    }
    guard let bufferURL, try await stageAudio(at: bufferURL, engine: engine, to: destination) else { return nil }
    return blockAudio(destination, mimeType: "audio/mp4", source: .video, of: block, trimmedBy: fill,
                      engine: engine)
  }

  /// The source an audio block reads from; `nil` when `audio/fileURI` is unset or unparseable.
  private static func audioFileURL(of audioBlock: DesignBlockID, engine: Engine) throws -> URL? {
    URL(string: try engine.block.getString(audioBlock, property: "audio/fileURI"))
  }

  /// The ceiling on how much of a source is resident at once, whichever way it is read.
  private static let chunkBytes = 1 << 20

  /// Copies an audio source into `destination` a chunk at a time; `false` when the source is empty.
  ///
  /// Never materialised as one `Data`: a scene's audio is unbounded, and a single long recording is
  /// enough to exhaust memory on its own.
  private static func stageAudio(at url: URL, engine: Engine, to destination: URL) async throws -> Bool {
    let written = switch AudioReader(url: url) {
    case .buffer: try stageBuffer(at: url, engine: engine, to: destination)
    case .resource: try stageResource(at: url, engine: engine, to: destination)
    case .remote: try await stageRemote(at: url, to: destination)
    }
    if written <= 0 {
      try? FileManager.default.removeItem(at: destination)
    }
    return written > 0
  }

  /// Sliced rather than read whole: `getBufferData` allocates whatever length it is asked for, so the
  /// request itself is what has to stay bounded.
  ///
  /// The read stays on the main actor — the engine is single-threaded, so reading its buffer from
  /// anywhere else would be reaching across that boundary — and each slice is written before the next is
  /// asked for.
  private static func stageBuffer(at url: URL, engine: Engine, to destination: URL) throws -> Int {
    let length = Int(try engine.editor.getBufferLength(url: url).uintValue)
    guard length > 0 else { return 0 }
    let file = try openForWriting(destination)
    defer { try? file.close() }
    var written = 0
    while written < length {
      let chunk = try engine.editor.getBufferData(url: url, offset: UInt(written),
                                                  length: UInt(min(chunkBytes, length - written)))
      // A short read would otherwise spin: the offset never advances past it.
      guard !chunk.isEmpty else { break }
      try file.write(contentsOf: chunk)
      written += chunk.count
    }
    return written
  }

  /// Only resources the engine already holds are readable — which the preceding `forceLoadAVResource`
  /// guarantees.
  ///
  /// Each chunk is written inside the callback: the engine hands out a view it may reuse once the
  /// callback returns, and holding the chunks to join afterwards is the allocation this avoids.
  ///
  /// A failed write stops the walk by returning `false` rather than throwing, so the error is raised here
  /// instead of unwinding through the engine's callback.
  private static func stageResource(at url: URL, engine: Engine, to destination: URL) throws -> Int {
    let file = try openForWriting(destination)
    defer { try? file.close() }
    var written = 0
    var failure: (any Error)?
    try engine.editor.getResourceData(url: url, chunkSize: UInt(chunkBytes)) { chunk in
      do {
        try file.write(contentsOf: chunk)
      } catch {
        failure = error
        return false
      }
      written += chunk.count
      return true
    }
    if let failure {
      throw failure
    }
    return written
  }

  /// `download` streams the response straight to a temporary file, so a long recording never has to be
  /// resident. Cancelling the generation aborts a download in progress, as `data(from:)` did.
  private static func stageRemote(at url: URL, to destination: URL) async throws -> Int {
    let (downloaded, response) = try await URLSession.shared.download(from: url)
    if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
      try? FileManager.default.removeItem(at: downloaded)
      throw AudioSourceError.httpError(url: url, statusCode: http.statusCode)
    }
    try FileManager.default.moveItem(at: downloaded, to: destination)
    return try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
  }

  /// Creates `destination` empty and opens it for writing; the caller closes the handle.
  private static func openForWriting(_ destination: URL) throws -> FileHandle {
    guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
    }
    return try FileHandle(forWritingTo: destination)
  }

  /// Maps a staged whole-track audio file to a `BlockAudio`, taking the timeline placement from `block`
  /// and clipping cues to `trimmed`'s (playback-only) trim window and speed. A speed the engine cannot
  /// report — or reports as non-positive or non-finite — falls back to real time.
  private static func blockAudio(
    _ url: URL,
    mimeType: String,
    source: Source,
    of block: DesignBlockID,
    trimmedBy trimmed: DesignBlockID,
    engine: Engine,
  ) -> BlockAudio {
    let trimOffset = (try? engine.block.getTrimOffset(trimmed)) ?? 0
    let trimLength = (try? engine.block.getTrimLength(trimmed)) ?? 0
    let windowEnd = trimLength > 0 ? trimOffset + trimLength : .infinity
    let speed = Double((try? engine.block.getPlaybackSpeed(trimmed)) ?? 1)
    return BlockAudio(url: url, mimeType: mimeType, source: source,
                      timeOffset: (try? engine.block.getTimeOffset(block)) ?? 0,
                      windowStart: trimOffset, windowEnd: windowEnd,
                      speed: speed.isFinite && speed > 0 ? speed : 1)
  }

  /// Whether a block (or a video's fill) contributes audible sound: not muted and volume above zero.
  private static func isAudible(_ id: DesignBlockID, engine: Engine) throws -> Bool {
    try !engine.block.isMuted(id) && engine.block.getVolume(id) > 0
  }

  // MARK: - Transcription (parallel, network-bound)

  private static func transcribe(
    _ audios: [BlockAudio],
    provider: any TranscriptionProvider,
    options: TranscriptionOptions,
  ) async throws -> [SubtitleCue] {
    var blocks: [TranscribedBlock] = []
    var firstError: (any Error)?
    try await withThrowingTaskGroup(of: Result<TranscribedBlock, any Error>.self) { group in
      for audio in audios {
        group.addTask {
          do {
            let srt = try await provider.transcribe(audio: audio.url, mimeType: audio.mimeType, options: options)
            return .success(TranscribedBlock(srt: srt, source: audio.source, timeOffset: audio.timeOffset,
                                             windowStart: audio.windowStart,
                                             windowEnd: audio.windowEnd, speed: audio.speed))
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            // Collected below — one block's failure must not cancel its siblings.
            return .failure(error)
          }
        }
      }

      for try await result in group {
        switch result {
        case let .success(block):
          blocks.append(block)
        case let .failure(error):
          let message = "Transcription failed via \(provider.name): \(error.localizedDescription)"
          Logger.autoCaptions.error("\(message, privacy: .public)")
          if firstError == nil {
            firstError = error
          }
        }
      }
    }
    // Cancelled provider calls surface as transport errors and land in `firstError` — report the
    // cancellation itself instead.
    try Task.checkCancellation()

    let cues = timelineCues(from: blocks)
    // Surface a real failure whenever nothing was produced — a silent (empty-success) block must not
    // mask a sibling's transport error as "no speech".
    if cues.isEmpty, let firstError {
      throw firstError
    }
    return cues
  }
}
