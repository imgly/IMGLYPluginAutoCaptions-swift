import Foundation

/// A single subtitle cue with timings in seconds.
struct SubtitleCue: Equatable, Sendable {
  var start: TimeInterval
  var end: TimeInterval
  var text: String
}

/// SRT parsing and serialization for the generate flow.
///
/// Providers return SRT text with timings relative to their audio, which must be shifted by the source
/// block's position on the timeline and merged across blocks before the editor imports the result —
/// that requires round-tripping through cues here. The parser is deliberately lenient (the engine's
/// strict parser validates the final file on import): cue blocks are separated by blank lines, the
/// index line is optional, and both `,` and `.` millisecond separators are accepted.
enum SRT {
  /// Parses SRT text into cues, skipping malformed blocks.
  static func parse(_ srt: String) -> [SubtitleCue] {
    let normalized = srt.replacingOccurrences(of: "\r\n", with: "\n")
    let blocks = normalized.components(separatedBy: "\n\n")
    return blocks.compactMap { block in
      let lines = block.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
      let timings = lines[timingIndex].components(separatedBy: "-->")
      guard timings.count == 2,
            let start = seconds(fromTimestamp: timings[0]),
            let end = seconds(fromTimestamp: timings[1]) else { return nil }
      let text = lines[(timingIndex + 1)...].joined(separator: "\n")
      guard !text.isEmpty else { return nil }
      return SubtitleCue(start: start, end: end, text: text)
    }
  }

  /// Serializes cues into SRT text, numbering them in the given order.
  static func serialize(_ cues: [SubtitleCue]) -> String {
    cues.enumerated().map { index, cue in
      "\(index + 1)\n\(timestamp(cue.start)) --> \(timestamp(cue.end))\n\(cue.text)"
    }
    .joined(separator: "\n\n")
  }

  /// Formats seconds as an SRT timestamp: `HH:MM:SS,mmm`.
  static func timestamp(_ seconds: TimeInterval) -> String {
    let totalMilliseconds = Int((seconds * 1000).rounded())
    let milliseconds = totalMilliseconds % 1000
    let totalSeconds = totalMilliseconds / 1000
    let secondsPart = totalSeconds % 60
    let totalMinutes = totalSeconds / 60
    let minutes = totalMinutes % 60
    let hours = totalMinutes / 60
    return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secondsPart, milliseconds)
  }

  /// Parses an SRT timestamp (`HH:MM:SS,mmm`, also tolerating `MM:SS,mmm` and a `.` separator) into
  /// seconds, or `nil` if malformed.
  static func seconds(fromTimestamp timestamp: String) -> TimeInterval? {
    let trimmed = timestamp.trimmingCharacters(in: .whitespaces)
    let parts = trimmed.components(separatedBy: ":")
    guard (2 ... 3).contains(parts.count) else { return nil }

    let secondsPart = parts[parts.count - 1].replacingOccurrences(of: ",", with: ".")
    guard let seconds = TimeInterval(secondsPart), seconds >= 0 else { return nil }
    var units = parts.dropLast().compactMap { Int($0) }
    guard units.count == parts.count - 1, units.allSatisfy({ $0 >= 0 }) else { return nil }

    if units.count == 1 {
      units.insert(0, at: 0) // No hours component.
    }
    return TimeInterval(units[0]) * 3600 + TimeInterval(units[1]) * 60 + seconds
  }
}
