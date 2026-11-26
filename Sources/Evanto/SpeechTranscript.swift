import CoreMedia
import Foundation
import Speech

struct SpeechUpdate {
    struct Piece {
        let range: CMTimeRange
        let text: String
    }

    let range: CMTimeRange
    let finalizedThrough: CMTime
    let text: String
    var pieces: [Piece] = []

    init(range: CMTimeRange, finalizedThrough: CMTime, text: String, pieces: [Piece] = []) {
        self.range = range
        self.finalizedThrough = finalizedThrough
        self.text = text
        self.pieces = pieces
    }

    init(_ result: SpeechTranscriber.Result) {
        range = result.range
        finalizedThrough = result.resultsFinalizationTime
        text = String(result.text.characters)
        // Attach leading/trailing punctuation and whitespace to timed words.
        var leading = ""
        for run in result.text.runs {
            let string = String(result.text[run.range].characters)
            if let time = run.audioTimeRange {
                pieces.append(Piece(range: time, text: leading + string))
                leading = ""
            } else if let last = pieces.popLast() {
                pieces.append(Piece(range: last.range, text: last.text + string))
            } else { leading += string }
        }
    }
}

struct SpeechTranscript {
    struct Segment {
        let stream: UUID
        let source: AudioSource
        let range: CMTimeRange
        let text: String
        let pieces: [SpeechUpdate.Piece]
        var final = false

        func retaining(_ words: [SpeechUpdate.Piece]) -> Segment? {
            guard let first = words.first, let last = words.last else { return nil }
            let text = words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Segment(stream: stream, source: source, range: CMTimeRange(start: first.range.start, end: last.range.end),
                           text: text, pieces: words, final: final)
        }
    }

    private(set) var segments: [Segment] = []

    // Volatile results can be revised, span several older results, or become
    // final without being delivered a second time. Reconcile by audio time.
    mutating func apply(_ update: SpeechUpdate, stream: UUID, source: AudioSource) -> [Segment] {
        guard update.range.isValid, update.range.start.isNumeric else { return [] }
        var kept = [Segment]()
        for old in segments {
            guard update.range.duration > .zero, old.stream == stream, !old.final,
                  old.range.start < update.range.end, old.range.end > update.range.start else {
                kept.append(old)
                continue
            }
            if old.range.start < update.range.start,
               let prefix = old.retaining(old.pieces.filter { $0.range.end <= update.range.start }) { kept.append(prefix) }
            if old.range.end > update.range.end,
               let suffix = old.retaining(old.pieces.filter { $0.range.start >= update.range.end }) { kept.append(suffix) }
        }
        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, !kept.contains(where: { $0.stream == stream && $0.final && $0.range == update.range }) {
            kept.append(Segment(stream: stream, source: source, range: update.range, text: text, pieces: update.pieces))
        }
        kept.sort {
            if $0.range.start != $1.range.start { return $0.range.start < $1.range.start }
            return $0.source.rawValue < $1.source.rawValue
        }
        var finalized = [Segment]()
        if update.finalizedThrough.isNumeric {
            for i in kept.indices where kept[i].stream == stream && !kept[i].final && kept[i].range.end <= update.finalizedThrough {
                kept[i].final = true
                finalized.append(kept[i])
            }
        }
        segments = kept
        return finalized
    }

    mutating func finish(_ stream: UUID) {
        for i in segments.indices where segments[i].stream == stream { segments[i].final = true }
    }

    var text: String {
        var lines = [String]()
        var previous: Segment?
        for segment in segments {
            if let previous, previous.stream == segment.stream,
               (segment.range.start - previous.range.end).seconds < 1.6 {
                lines[lines.count - 1] += " " + segment.text
            } else { lines.append(segment.source.rawValue + " · " + segment.text) }
            previous = segment
        }
        return lines.joined(separator: "\n")
    }
}

enum ReplyPause: Int, CaseIterable {
    case short = 2, standard = 3, long = 5
    var duration: Duration { .seconds(rawValue) }
}

struct SpokenTurn {
    var end: CMTime
    var text: String
    var lastSegmentText: String
}

// SpeechAnalyzer can keep an utterance volatile for the whole time the
// input stays open. Use its words and audio range to track what was answered.
struct SpokenReplyCursor {
    private var through: CMTime?
    private var answeredText = ""

    mutating func consume(_ turn: SpokenTurn) {
        through = turn.end
        answeredText = turn.lastSegmentText
    }

    func pending(in transcript: SpeechTranscript, stream: UUID, pause: ReplyPause) -> [SpokenTurn] {
        var turns: [SpokenTurn] = []
        for segment in transcript.segments where segment.stream == stream {
            var start = segment.range.start, text = segment.text
            if let through {
                if segment.range.end <= through { continue }
                if start < through {
                    if !segment.pieces.isEmpty {
                        let remaining = segment.pieces.filter { $0.range.start >= through }
                        text = remaining.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                    } else {
                        // A model may omit word timing. Strip the already-answered
                        // prefix when the recognizer extends its previous range.
                        let covered = answeredText.split(whereSeparator: \.isWhitespace)
                        let words = text.split(whereSeparator: \.isWhitespace)
                        let prefix = words.prefix(covered.count).joined(separator: " ")
                        guard !covered.isEmpty, Questions.key(prefix) == Questions.key(answeredText) else { continue }
                        text = words.dropFirst(covered.count).joined(separator: " ")
                    }
                    start = through
                }
            }
            guard !text.isEmpty else { continue }
            let gap = turns.last.map { (start - $0.end).seconds } ?? 0
            // Recognition finalizes sentences separately. Only a pause in the
            // source audio separates one speaker turn from the next.
            if !turns.isEmpty, gap < Double(pause.rawValue) {
                turns[turns.count - 1].text += " " + text
                turns[turns.count - 1].end = segment.range.end
                turns[turns.count - 1].lastSegmentText = segment.text
            } else {
                turns.append(SpokenTurn(end: segment.range.end, text: text, lastSegmentText: segment.text))
            }
        }
        return turns
    }
}
