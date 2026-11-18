import Foundation
import Combine
import GRDB
import Libavcodec
import Libavformat
import Libavutil

// B2 (build 61, item 2): live recording / DVR.
//
// A recording is a real-time remux (stream copy, no re-encode) of a
// live channel into the existing Downloads storage, using the same
// Libavformat pattern as the AirPlay remux writer
// (`RemuxHLSWriter`): open the live URL with reconnect options and
// an interrupt callback, copy the first video + first audio stream
// into an MPEG-TS file, rescale timestamps, repair them with the
// shared `RemuxHLSWriter.TimestampRepair`.
//
// The recording is a `DBDownloadedItem` row (type "recording",
// status downloading → completed/failed), so it lives in
// DownloadsView alongside downloads and is counted by the storage
// cap. Recordings are NOT URLSession downloads: `DownloadManager`
// never starts them (see its pump/restore guards) — this service is
// their only owner.
//
// HONEST LIMITS: recording is real-time only (a 1-hour recording
// takes 1 hour) and runs only while the app is in the foreground —
// iOS suspends the process in the background and there is no
// background-recording guarantee. If the app is killed mid-recording,
// the partial file is finalized on next launch by DownloadManager's
// restore pass (kept as a completed recording when it has content).

/// The FFmpeg copy loop for one recording. Runs on its own queue;
/// `stop()` interrupts the blocking read so the file is finalized
/// (trailer written) instead of truncated.
final class LiveStreamRecorder {
    enum RecorderError: LocalizedError {
        case openInputFailed(Int32)
        case noVideoStream
        case openOutputFailed(Int32)
        case writeFailed(Int32)
        case readFailed(Int32)

        var errorDescription: String? {
            switch self {
            case let .openInputFailed(code): return "recording: input open failed (\(code))"
            case .noVideoStream: return "recording: no video stream"
            case let .openOutputFailed(code): return "recording: output open failed (\(code))"
            case let .writeFailed(code): return "recording: write failed (\(code))"
            case let .readFailed(code): return "recording: source read failed (\(code))"
            }
        }
    }

    /// AVERROR_EOF (see RemuxHLSWriter).
    private static let avErrorEOF: Int32 = -541_478_725

    private let sourceURL: URL
    private let outputURL: URL
    private let queue = DispatchQueue(label: "superx.recording.writer", qos: .userInitiated)
    /// Read by the FFmpeg interrupt callback; breaks the blocking
    /// `av_read_frame` when the user stops the recording.
    private let cancelled = UnsafeMutablePointer<Int32>.allocate(capacity: 1)

    /// Called on the writer queue with the bytes written so far.
    var onProgress: ((Int64) -> Void)?
    /// Called once on the writer queue: nil error = the file was
    /// finalized cleanly (user stop or a clean end of stream).
    var onFinish: ((Error?) -> Void)?

    init(sourceURL: URL, outputURL: URL) {
        self.sourceURL = sourceURL
        self.outputURL = outputURL
        cancelled.pointee = 0
    }

    deinit {
        cancelled.deallocate()
    }

    func start() {
        queue.async { [self] in
            var finishError: Error?
            do {
                try runCopyLoop()
            } catch {
                // A user stop interrupts the read, which surfaces as
                // a read error — that is a clean finish, not a failure.
                if cancelled.pointee == 0 {
                    finishError = error
                }
            }
            onFinish?(finishError)
        }
    }

    func stop() {
        cancelled.pointee = 1
    }

    private func runCopyLoop() throws {
        var inputCtx: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
        inputCtx?.pointee.interrupt_callback.callback = { opaque in
            opaque?.assumingMemoryBound(to: Int32.self).pointee ?? 0
        }
        inputCtx?.pointee.interrupt_callback.opaque = UnsafeMutableRawPointer(cancelled)

        var inputOpts: OpaquePointer?
        defer { av_dict_free(&inputOpts) }
        av_dict_set(&inputOpts, "reconnect", "1", 0)
        av_dict_set(&inputOpts, "reconnect_streamed", "1", 0)
        av_dict_set(&inputOpts, "reconnect_at_eof", "1", 0)
        av_dict_set(&inputOpts, "rw_timeout", "15000000", 0)
        av_dict_set(&inputOpts, "analyzeduration", "2000000", 0)
        av_dict_set(&inputOpts, "probesize", "1500000", 0)

        var openResult = avformat_open_input(&inputCtx, sourceURL.absoluteString, nil, &inputOpts)
        guard openResult >= 0, let input = inputCtx else {
            throw RecorderError.openInputFailed(openResult)
        }
        defer {
            var closing: UnsafeMutablePointer<AVFormatContext>? = input
            avformat_close_input(&closing)
        }
        openResult = avformat_find_stream_info(input, nil)
        guard openResult >= 0 else { throw RecorderError.openInputFailed(openResult) }

        // Stream selection: first video + first audio, both copied.
        // (A recording does not need the AirPlay writer's
        // AVPlayer-compatibility filter — the in-app player reads
        // the .ts with the FFmpeg backend.)
        var videoInputIndex = -1
        var audioInputIndex = -1
        for i in 0..<Int(input.pointee.nb_streams) {
            guard let inStream = input.pointee.streams[i],
                  let codecpar = inStream.pointee.codecpar
            else { continue }
            switch codecpar.pointee.codec_type {
            case AVMEDIA_TYPE_VIDEO:
                if videoInputIndex < 0 { videoInputIndex = i }
            case AVMEDIA_TYPE_AUDIO:
                if audioInputIndex < 0 { audioInputIndex = i }
            default:
                break
            }
        }
        guard videoInputIndex >= 0 else { throw RecorderError.noVideoStream }

        let outputPath = outputURL.path
        var outCtx: UnsafeMutablePointer<AVFormatContext>?
        var result = avformat_alloc_output_context2(&outCtx, nil, "mpegts", outputPath)
        guard result >= 0, let output = outCtx else {
            throw RecorderError.openOutputFailed(result)
        }
        defer { avformat_free_context(output) }

        // Output stream 0 = video, 1 = audio (when present).
        var streamMap: [Int: Int] = [:]
        for (outIndex, inIndex) in [videoInputIndex, audioInputIndex].enumerated() where inIndex >= 0 {
            guard let inStream = input.pointee.streams[inIndex],
                  let outStream = avformat_new_stream(output, nil)
            else { throw RecorderError.openOutputFailed(-1) }
            result = avcodec_parameters_copy(outStream.pointee.codecpar, inStream.pointee.codecpar)
            guard result >= 0 else { throw RecorderError.openOutputFailed(result) }
            outStream.pointee.codecpar.pointee.codec_tag = 0
            streamMap[inIndex] = outIndex
        }

        result = avio_open(&output.pointee.pb, outputPath, AVIO_FLAG_WRITE)
        guard result >= 0 else { throw RecorderError.openOutputFailed(result) }
        defer { avio_closep(&output.pointee.pb) }

        result = avformat_write_header(output, nil)
        guard result >= 0 else { throw RecorderError.openOutputFailed(result) }
        defer { av_write_trailer(output) }

        var videoClock = RemuxHLSWriter.TimestampRepair()
        var audioClock = RemuxHLSWriter.TimestampRepair()
        var packet = AVPacket()
        var lastProgressAt = Date()
        var wroteAnyPacket = false
        while cancelled.pointee == 0 {
            let readResult = av_read_frame(input, &packet)
            if readResult == Self.avErrorEOF {
                // Live EOF = the source dropped the connection. The
                // bytes already written are a valid recording; the
                // service decides by final size.
                break
            }
            if readResult < 0 { throw RecorderError.readFailed(readResult) }
            defer { av_packet_unref(&packet) }
            let inIndex = Int(packet.stream_index)
            guard let outIndex = streamMap[inIndex],
                  let inStream = input.pointee.streams[inIndex],
                  let outStream = output.pointee.streams[outIndex]
            else { continue }

            if outIndex == 0 {
                guard let repaired = videoClock.repairVideo(pts: packet.pts, duration: packet.duration)
                else { continue }
                packet.pts = repaired.pts
                packet.dts = repaired.dts
            } else {
                guard let repaired = audioClock.repairAudio(pts: packet.pts, dts: packet.dts, duration: packet.duration)
                else { continue }
                packet.pts = repaired.pts
                packet.dts = repaired.dts
            }
            packet.stream_index = Int32(outIndex)
            av_packet_rescale_ts(&packet, inStream.pointee.time_base, outStream.pointee.time_base)
            let writeResult = av_interleaved_write_frame(output, &packet)
            if writeResult < 0 { throw RecorderError.writeFailed(writeResult) }
            wroteAnyPacket = true

            if Date().timeIntervalSince(lastProgressAt) >= 1.0 {
                lastProgressAt = Date()
                if let pb = output.pointee.pb {
                    onProgress?(avio_tell(pb))
                }
            }
        }
        if !wroteAnyPacket, cancelled.pointee == 0 {
            throw RecorderError.readFailed(-1)
        }
    }
}

/// Owns the active recordings and their DB rows.
@MainActor
final class LiveRecordingService: ObservableObject {
    static let shared = LiveRecordingService()

    struct ActiveRecording: Identifiable {
        let id: String
        let playlistId: UUID
        let streamId: Int
        let title: String
        let startedAt: Date
        var bytesWritten: Int64
    }

    @Published private(set) var active: [String: ActiveRecording] = [:]
    /// Advances once a second while any recording is active, so
    /// elapsed-time labels re-render without a per-row timer.
    @Published private(set) var now = Date()

    private var writers: [String: LiveStreamRecorder] = [:]
    /// Ids the user cancelled: their files and rows are discarded
    /// when the writer finishes, instead of being kept.
    private var discardIds: Set<String> = []
    private var tickTimer: Timer?

    private init() {}

    /// The id of the in-progress recording for a channel, if any.
    func activeRecordingId(playlistId: UUID, streamId: Int) -> String? {
        active.values.first { $0.playlistId == playlistId && $0.streamId == streamId }?.id
    }

    func isRecording(id: String) -> Bool { active[id] != nil }

    /// Starts recording a live Xtream channel. Creates the Downloads
    /// row first (status downloading, type "recording"); when the
    /// storage cap is already reached the row is created as failed
    /// with the cap notice instead — never a silent no-op.
    func start(playlist: Playlist, stream: DBLiveStream) async {
        guard activeRecordingId(playlistId: playlist.id, streamId: stream.streamId) == nil else { return }
        guard let remoteURL = PlaybackURLBuilder(playlist: playlist).liveURL(streamId: stream.streamId) else { return }

        let epoch = Int(Date().timeIntervalSince1970)
        let id = "recording.\(playlist.id.uuidString).\(stream.streamId).\(epoch)"
        let relPath = DownloadStorage.relativePath(
            playlistId: playlist.id, type: "recording",
            streamId: "\(stream.streamId)-\(epoch)", ext: "ts"
        )

        if DownloadStorage.totalUsedBytes() >= DownloadManager.storageCapBytes {
            await insertRow(
                id: id, playlist: playlist, stream: stream, remoteURL: remoteURL,
                relPath: relPath, status: DownloadStatus.failed,
                errorMessage: L("downloadcap.blocked")
            )
            return
        }

        guard let outputURL = try? DownloadStorage.ensureParentDirectory(for: relPath) else {
            await insertRow(
                id: id, playlist: playlist, stream: stream, remoteURL: remoteURL,
                relPath: relPath, status: DownloadStatus.failed,
                errorMessage: L("record.failed")
            )
            return
        }

        await insertRow(
            id: id, playlist: playlist, stream: stream, remoteURL: remoteURL,
            relPath: relPath, status: DownloadStatus.downloading, errorMessage: nil
        )

        let writer = LiveStreamRecorder(sourceURL: remoteURL, outputURL: outputURL)
        writers[id] = writer
        active[id] = ActiveRecording(
            id: id, playlistId: playlist.id, streamId: stream.streamId,
            title: stream.name, startedAt: Date(), bytesWritten: 0
        )
        startTickingIfNeeded()
        writer.onProgress = { [weak self] bytes in
            Task { @MainActor [weak self] in
                self?.active[id]?.bytesWritten = bytes
            }
        }
        writer.onFinish = { [weak self] error in
            Task { @MainActor [weak self] in
                await self?.handleFinish(id: id, relPath: relPath, error: error)
            }
        }
        writer.start()
        DownloadManager.shared.bumpDBVersion()
    }

    /// Stops the recording and KEEPS the file: the row becomes a
    /// completed download.
    func stop(id: String) {
        writers[id]?.stop()
    }

    /// Cancels every active recording belonging to a playlist
    /// (playlist deletion path in `DownloadManager.cleanupPlaylist`).
    func cancelRecordings(playlistId: UUID) {
        for recording in active.values where recording.playlistId == playlistId {
            cancel(id: recording.id)
        }
    }

    /// Cancels every active recording (delete-all-downloads path).
    func cancelAllRecordings() {
        for recording in active.values {
            cancel(id: recording.id)
        }
    }

    /// Stops the recording and DISCARDS the file and its row.
    func cancel(id: String) {
        discardIds.insert(id)
        if let writer = writers[id] {
            writer.stop()
        } else {
            Task { await handleFinish(id: id, relPath: nil, error: nil) }
        }
    }

    private func handleFinish(id: String, relPath: String?, error: Error?) async {
        writers.removeValue(forKey: id)
        active.removeValue(forKey: id)
        if active.isEmpty { stopTicking() }
        let discard = discardIds.remove(id) != nil

        if discard {
            if let relPath { DownloadStorage.removeFile(relativePath: relPath) }
            _ = try? await AppDatabase.shared.write { db in
                try DBDownloadedItem.filter(Column("id") == id).deleteAll(db)
            }
            DownloadManager.shared.bumpDBVersion()
            return
        }

        // Final size from disk — the single source of truth for
        // whether anything usable was recorded.
        var finalSize: Int64 = 0
        var resolvedRelPath = relPath
        if resolvedRelPath == nil {
            resolvedRelPath = try? await AppDatabase.shared.read { db in
                try DBDownloadedItem.filter(Column("id") == id).fetchOne(db)?.localPath
            }
        }
        if let resolvedRelPath,
           let url = try? DownloadStorage.absoluteURL(forRelativePath: resolvedRelPath),
           let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            finalSize = (attrs[.size] as? Int64) ?? 0
        }

        _ = try? await AppDatabase.shared.write { db in
            guard var row = try DBDownloadedItem.filter(Column("id") == id).fetchOne(db) else { return }
            if error == nil, finalSize > 0 {
                row.status = DownloadStatus.completed.rawValue
                row.totalBytes = Int(finalSize)
                row.downloadedBytes = Int(finalSize)
                row.completedAt = Date()
                row.errorMessage = nil
            } else {
                row.status = DownloadStatus.failed.rawValue
                row.errorMessage = L("record.failed")
                // A failed recording's partial file is not playable
                // content — remove it; the failed row stays visible
                // with the reason and a retry path.
                if let resolvedRelPath {
                    DownloadStorage.removeFile(relativePath: resolvedRelPath)
                }
            }
            try row.update(db)
        }
        DownloadManager.shared.bumpDBVersion()
    }

    private func insertRow(
        id: String, playlist: Playlist, stream: DBLiveStream,
        remoteURL: URL, relPath: String,
        status: DownloadStatus, errorMessage: String?
    ) async {
        _ = try? await AppDatabase.shared.write { db in
            let item = DBDownloadedItem(
                id: id,
                playlistId: playlist.id,
                streamId: String(stream.streamId),
                type: "recording",
                title: stream.name,
                secondaryTitle: nil,
                imageURL: stream.streamIcon,
                remoteURL: remoteURL.absoluteString,
                localPath: relPath,
                containerExtension: "ts",
                totalBytes: 0,
                downloadedBytes: 0,
                status: status.rawValue,
                errorMessage: errorMessage,
                createdAt: Date(),
                completedAt: nil,
                seriesId: nil,
                seasonNumber: nil,
                episodeNumber: nil
            )
            try item.save(db)
        }
        DownloadManager.shared.bumpDBVersion()
    }

    private func startTickingIfNeeded() {
        guard tickTimer == nil else { return }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.now = Date()
            }
        }
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }
}
