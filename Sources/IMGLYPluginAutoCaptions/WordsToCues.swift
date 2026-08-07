import Foundation

/// A single word with its start and end timestamps.
struct TimedWord: Sendable {
  var text: String
  var start: TimeInterval
  var end: TimeInterval
}

extension SubtitleCue {
  /// Groups timed words into subtitle cues respecting the line-length and line-count limits, using the
  /// first word's start and the last word's end as the cue timestamps.
  static func cues(from words: [TimedWord], maxLineLength: Int, maxLines: Int) -> [SubtitleCue] {
    var cues: [SubtitleCue] = []
    var cueWords: [TimedWord] = []
    var lines: [String] = []
    var currentLine = ""

    func flushCue() {
      guard let first = cueWords.first, let last = cueWords.last else { return }
      if !currentLine.isEmpty {
        lines.append(currentLine)
      }
      cues.append(SubtitleCue(start: first.start, end: last.end, text: lines.joined(separator: "\n")))
      cueWords = []
      lines = []
      currentLine = ""
    }

    for word in words {
      let candidate = currentLine.isEmpty ? word.text : "\(currentLine) \(word.text)"

      // Measure in UTF-16 code units, not grapheme clusters: emoji / astral / combining-mark text
      // counts as multiple code units, so grapheme counting would wrap on a different word and give
      // inconsistent line lengths for such text.
      if candidate.utf16.count > maxLineLength, !currentLine.isEmpty {
        // The current line is full.
        lines.append(currentLine)
        currentLine = ""

        if lines.count >= maxLines {
          // The cue is full — flush before starting this word.
          flushCue()
          currentLine = word.text
          cueWords = [word]
        } else {
          currentLine = word.text
          cueWords.append(word)
        }
      } else {
        currentLine = candidate
        cueWords.append(word)
      }
    }

    flushCue()
    return cues
  }
}
