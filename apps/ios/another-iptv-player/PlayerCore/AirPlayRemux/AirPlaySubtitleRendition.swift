import Foundation

/// Builds the HLS WebVTT subtitle rendition served alongside the remuxed video so
/// subtitles show on the AirPlay target. The remuxed TS video segments carry absolute
/// source PTS, and WebVTT cues are emitted in verbatim source (SRT) time with
/// `X-TIMESTAMP-MAP:MPEGTS:0` — so cue N lines up with the video frame at source-time N
/// whether the cast started from 0:00 or from a resume position (both are absolute
/// source time). If a panel's muxer applied a constant PTS offset, only `mpegtsClock`
/// needs tuning — the cue times stay put.
///
/// Phase 1 covers text subtitles (external SRT) over the H.264/MPEG-TS remux path.
/// HEVC/fMP4 and bitmap (PGS/DVB) subtitles are out of scope here.
enum AirPlaySubtitleRendition {
  static let videoGroupID = "subs"

  /// Parsed cues + the WebVTT document + the span the cues cover. `nil` when the file
  /// can't be read or has no usable cues.
  struct Built {
    let webVTT: String
    let durationSeconds: Double
  }

  /// Reads an SRT file and returns the WebVTT document. Returns nil for an unreadable
  /// or empty file (caller then skips the rendition and casts video-only).
  static func build(fromSRTFile url: URL, mpegtsClock: Int64 = 0) -> Built? {
    build(fromSubtitleFile: url, mpegtsClock: mpegtsClock)
  }

  /// Round 15 (C2): reads an imported subtitle file (SRT or
  /// WebVTT) and returns the WebVTT document for the rendition.
  ///
  /// Decoding: provider subtitle files in the wild are frequently
  /// NOT UTF-8 — a strict UTF-8 read used to fail the whole
  /// rendition (video-only cast, no explanation). The decode now
  /// falls back UTF-8 → Windows-1256 (Arabic, the most common
  /// legacy encoding for this app's subtitle sources) →
  /// ISO-8859-1, which maps every byte and so always succeeds.
  ///
  /// Parsing: WebVTT files (by extension or the `WEBVTT` header)
  /// route to the WebVTT parser below, NOT `SRTParser` — SRT
  /// parsing breaks on VTT cue settings and header blocks.
  static func build(fromSubtitleFile url: URL, mpegtsClock: Int64 = 0) -> Built? {
    guard let content = decodeSubtitleText(at: url) else { return nil }
    let isWebVTT = url.pathExtension.lowercased() == "vtt"
      || content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("WEBVTT")
    let entries = isWebVTT ? WebVTTParser.parse(content: content) : SRTParser().parse(content: content)
    guard !entries.isEmpty else { return nil }
    return build(from: entries, mpegtsClock: mpegtsClock)
  }

  /// UTF-8 → Windows-1256 → ISO-8859-1 decode chain (see above).
  private static func decodeSubtitleText(at url: URL) -> String? {
    if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
      return utf8
    }
    guard let data = try? Data(contentsOf: url) else { return nil }
    // kCFStringEncodingWindowsArabic (0x0506) — no direct
    // String.Encoding case exists for Windows-1256.
    let windows1256 = String.Encoding(
      rawValue: CFStringConvertEncodingToNSStringEncoding(0x0506)
    )
    if let arabic = String(data: data, encoding: windows1256) {
      return arabic
    }
    return String(data: data, encoding: .isoLatin1)
  }

  static func build(from entries: [SubtitleEntry], mpegtsClock: Int64 = 0) -> Built {
    var out = "WEBVTT\n"
    out += "X-TIMESTAMP-MAP=MPEGTS:\(mpegtsClock),LOCAL:00:00:00.000\n\n"
    var maxEnd: Double = 0
    for entry in entries {
      let start = max(entry.startTime, 0)
      let end = max(entry.endTime, start + 0.1)
      maxEnd = max(maxEnd, end)
      // A stray "-->" inside cue text would break WebVTT parsing; harmless to neutralise.
      let text = entry.text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "-->", with: "->")
      out += "\(timestamp(start)) --> \(timestamp(end))\n\(text)\n\n"
    }
    return Built(webVTT: out, durationSeconds: maxEnd)
  }

  /// Subtitle media playlist: one WebVTT "segment" spanning the whole VOD.
  static func subtitleMediaPlaylist(vttFileName: String, durationSeconds: Double) -> String {
    let dur = max(durationSeconds, 1)
    return [
      "#EXTM3U",
      "#EXT-X-VERSION:3",
      "#EXT-X-TARGETDURATION:\(Int(dur.rounded(.up)))",
      "#EXT-X-MEDIA-SEQUENCE:0",
      "#EXT-X-PLAYLIST-TYPE:VOD",
      String(format: "#EXTINF:%.3f,", dur),
      vttFileName,
      "#EXT-X-ENDLIST",
      "",
    ].joined(separator: "\n")
  }

  /// Master playlist referencing the (unchanged) video media playlist + the subtitle group.
  /// Handed to the cast AVPlayer instead of the raw video playlist when a subtitle exists.
  static func masterPlaylist(
    videoPlaylistFileName: String,
    subtitlePlaylistFileName: String,
    name: String,
    languageCode: String?
  ) -> String {
    var mediaLine =
      "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"\(videoGroupID)\",NAME=\"\(sanitize(name))\","
    mediaLine += "DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,"
    if let lang = languageCode, !lang.isEmpty {
      mediaLine += "LANGUAGE=\"\(sanitize(lang))\","
    }
    mediaLine += "URI=\"\(subtitlePlaylistFileName)\""
    return [
      "#EXTM3U",
      "#EXT-X-VERSION:3",
      "#EXT-X-INDEPENDENT-SEGMENTS",
      mediaLine,
      "#EXT-X-STREAM-INF:BANDWIDTH=6000000,SUBTITLES=\"\(videoGroupID)\"",
      videoPlaylistFileName,
      "",
    ].joined(separator: "\n")
  }

  // MARK: - Helpers

  private static func timestamp(_ seconds: TimeInterval) -> String {
    let ms = Int((max(seconds, 0) * 1000).rounded())
    let h = ms / 3_600_000
    let m = (ms % 3_600_000) / 60_000
    let s = (ms % 60_000) / 1000
    let milli = ms % 1000
    return String(format: "%02d:%02d:%02d.%03d", h, m, s, milli)
  }

  /// Strip characters that would break the m3u8 attribute quoting.
  private static func sanitize(_ value: String) -> String {
    value.replacingOccurrences(of: "\"", with: "")
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: ",", with: " ")
  }
}

/// Minimal WebVTT cue parser for the AirPlay path (round 15, C2):
/// handles the `WEBVTT` header block, NOTE/STYLE/REGION blocks,
/// optional cue identifiers, cue settings after the end time
/// (ignored), and both `HH:MM:SS.mmm` and `MM:SS.mmm` timestamps.
/// Produces the same `SubtitleEntry` values `SRTParser` returns so
/// the rendition builder doesn't care which format the file was.
enum WebVTTParser {
  static func parse(content: String) -> [SubtitleEntry] {
    var text = content
    if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
    let normalized = text
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    // Blocks are separated by blank lines.
    let blocks = normalized.components(separatedBy: "\n\n")
    var entries: [SubtitleEntry] = []
    for rawBlock in blocks {
      let lines = rawBlock.components(separatedBy: "\n")
      // Find the timing line; everything before it in the block is
      // the header (first block) or a cue identifier — both skipped.
      guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
      let timing = lines[timingIndex]
      let parts = timing.components(separatedBy: "-->")
      guard parts.count == 2,
            let start = parseTimestamp(parts[0]),
            let end = parseTimestamp(parts[1])
      else { continue }
      let textLines = lines[(timingIndex + 1)...]
        .map { stripTags($0) }
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      guard !textLines.isEmpty else { continue }
      entries.append(
        SubtitleEntry(startTime: start, endTime: end, text: textLines.joined(separator: "\n"))
      )
    }
    return entries
  }

  /// Parses one side of a timing line, dropping any cue settings
  /// that follow the timestamp (`… align:start position:0%`).
  private static func parseTimestamp(_ raw: String) -> TimeInterval? {
    let token = raw
      .trimmingCharacters(in: .whitespaces)
      .components(separatedBy: .whitespaces)
      .first ?? ""
    let components = token.components(separatedBy: ":")
    switch components.count {
    case 3:
      guard let h = Double(components[0]),
            let m = Double(components[1]),
            let s = Double(components[2]) else { return nil }
      return h * 3600 + m * 60 + s
    case 2:
      guard let m = Double(components[0]),
            let s = Double(components[1]) else { return nil }
      return m * 60 + s
    default:
      return nil
    }
  }

  private static func stripTags(_ line: String) -> String {
    guard line.contains("<") else { return line }
    return line.replacingOccurrences(
      of: "</?(i|b|u|c|v|font)[^>]*>",
      with: "",
      options: [.regularExpression, .caseInsensitive]
    )
  }
}
