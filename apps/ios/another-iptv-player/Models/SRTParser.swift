import Foundation

struct SubtitleEntry: Identifiable, Equatable {
    let id = UUID()
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}

/// Block-based SRT parser. The old Scanner version, because of its default whitespace skipping,
/// swallowed the blank lines between blocks and the WHOLE file collapsed into a single entry.
final class SRTParser {
    func parse(content: String) -> [SubtitleEntry] {
        // Skip the BOM; split with Character.isNewline without normalizing line endings.
        var text = Substring(content)
        if text.hasPrefix("\u{FEFF}") { text = text.dropFirst() }
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })

        var entries: [SubtitleEntry] = []
        var i = 0
        let n = lines.count
        while i < n {
            // Skip blank lines.
            while i < n, lines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
            guard i < n else { break }

            // Optional index line.
            if Int(lines[i].trimmingCharacters(in: .whitespaces)) != nil { i += 1 }
            guard i < n else { break }

            // Time line: 00:00:01,000 --> 00:00:04,000
            let timeLine = lines[i].trimmingCharacters(in: .whitespaces)
            let times = timeLine.components(separatedBy: " --> ")
            guard times.count == 2,
                  let start = parseTime(times[0]),
                  let end = parseTime(times[1]) else {
                // Broken block: skip to the next blank line.
                while i < n, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
                continue
            }
            i += 1

            // Text lines: up to a blank line or end of file.
            var textLines: [String] = []
            while i < n {
                let line = String(lines[i])
                if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
                textLines.append(stripBasicTags(line))
                i += 1
            }

            if !textLines.isEmpty {
                entries.append(SubtitleEntry(startTime: start, endTime: end, text: textLines.joined(separator: "\n")))
            }
        }

        return entries
    }

    /// Common decoration tags in SRT (<i>, <b>, <u>, <font ...>) are removed.
    private func stripBasicTags(_ line: String) -> String {
        guard line.contains("<") else { return line }
        return line.replacingOccurrences(
            of: "</?(i|b|u|font)[^>]*>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private func parseTime(_ timeString: String) -> TimeInterval? {
        let components = timeString.replacingOccurrences(of: ",", with: ".").components(separatedBy: ":")
        guard components.count == 3,
              let hours = Double(components[0]),
              let minutes = Double(components[1]),
              let seconds = Double(components[2]) else { return nil }

        return (hours * 3600) + (minutes * 60) + seconds
    }
}
