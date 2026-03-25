// WAVSpool.swift
// Kerwan — Transcription layer
//
// Disk-based backpressure spool for AudioChunks.
//
// When the in-memory transcription queue exceeds `maxQueueDepth` chunks,
// `TranscriptionActor` calls `WAVSpool.write` to persist excess chunks as
// IEEE-float WAV files.  A JSON sidecar preserves the metadata fields that
// the WAV format cannot carry (UUID, startTime, containsSpeech).
//
// File naming: queue_<ISO8601-timestamp>_<UUID>.wav
// Sidecar:     queue_<ISO8601-timestamp>_<UUID>.json
//
// Lexicographic sort of filenames gives chronological order because the
// timestamp component is ISO 8601 in UTC (dashes replace colons to satisfy
// filesystem constraints).
//
// WAV format
// ──────────
// IEEE float, mono, 32-bit, host sample rate.
// RIFF/WAVE layout:
//   "RIFF" <uint32 riff-size> "WAVE"
//   "fmt " <uint32 16> <uint16 3> <uint16 1> <uint32 sampleRate>
//          <uint32 byteRate> <uint16 blockAlign=4> <uint16 bitsPerSample=32>
//   "data" <uint32 dataBytes> <Float32 samples…>

import Foundation

// MARK: - WAVSpool

/// Value-type helper for persisting AudioChunks to disk.
///
/// All methods perform synchronous file I/O; callers in `TranscriptionActor`
/// should be aware that these operations briefly block the actor executor.
/// In practice, chunks are ~1.9 MB on flash storage (<5 ms); acceptable for
/// an edge-case backpressure path.
public struct WAVSpool: Sendable {

    // MARK: - Properties

    /// Directory where WAV + JSON files are written.
    public let directory: URL

    // MARK: - Init

    public init(directory: URL = WAVSpool.defaultDirectory) {
        self.directory = directory
    }

    /// Default spool directory: ~/Library/Application Support/Kerwan/AudioQueue/
    public static var defaultDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kerwan/AudioQueue", isDirectory: true)
    }

    // MARK: - Public API

    /// Creates the spool directory if it doesn't exist.
    /// Call once on `TranscriptionActor.start()`.
    func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    /// Writes `chunk` as a WAV + JSON sidecar and returns the WAV URL.
    func write(chunk: AudioChunk) throws -> URL {
        let basename = Self.basename(for: chunk)
        let wavURL   = directory.appendingPathComponent("\(basename).wav")
        let jsonURL  = directory.appendingPathComponent("\(basename).json")

        let wavData  = Self.makeWAV(pcmData: chunk.data, sampleRate: chunk.sampleRate)
        try wavData.write(to: wavURL, options: .atomic)

        let sidecar  = SpoolSidecar(
            id:              chunk.id,
            sampleRate:      chunk.sampleRate,
            startTime:       chunk.startTime,
            durationSeconds: chunk.durationSeconds,
            containsSpeech:  chunk.containsSpeech
        )
        let jsonData = try JSONEncoder().encode(sidecar)
        try jsonData.write(to: jsonURL, options: .atomic)

        return wavURL
    }

    /// Reads, reconstructs, and deletes the chunk at `wavURL`.
    ///
    /// The corresponding JSON sidecar is derived from the WAV filename.
    /// Returns `nil` if either file is missing or corrupt.
    @discardableResult
    func read(url wavURL: URL) throws -> AudioChunk? {
        let basename = wavURL.deletingPathExtension().lastPathComponent
        let jsonURL  = directory.appendingPathComponent("\(basename).json")

        // Read sidecar first; if it's missing the file is corrupt → skip.
        guard let jsonData = try? Data(contentsOf: jsonURL),
              let sidecar  = try? JSONDecoder().decode(SpoolSidecar.self, from: jsonData)
        else {
            // Clean up orphan WAV.
            try? FileManager.default.removeItem(at: wavURL)
            return nil
        }

        guard let wavData = try? Data(contentsOf: wavURL),
              let pcmData = Self.extractPCM(from: wavData)
        else {
            try? FileManager.default.removeItem(at: wavURL)
            try? FileManager.default.removeItem(at: jsonURL)
            return nil
        }

        // Delete both files after a successful read.
        try? FileManager.default.removeItem(at: wavURL)
        try? FileManager.default.removeItem(at: jsonURL)

        return AudioChunk(
            id:              sidecar.id,
            data:            pcmData,
            sampleRate:      sidecar.sampleRate,
            startTime:       sidecar.startTime,
            durationSeconds: sidecar.durationSeconds,
            containsSpeech:  sidecar.containsSpeech
        )
    }

    /// Returns sorted (chronological) list of spooled WAV URLs.
    func listFiles() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Number of spooled WAV files currently on disk.
    var fileCount: Int {
        (try? listFiles().count) ?? 0
    }

    // MARK: - Private: filename

    private static func basename(for chunk: AudioChunk) -> String {
        let ts = ISO8601DateFormatter().string(from: chunk.startTime)
            .replacingOccurrences(of: ":", with: "-")
        return "queue_\(ts)_\(chunk.id.uuidString)"
    }

    // MARK: - Private: WAV encode

    static func makeWAV(pcmData: Data, sampleRate: Int) -> Data {
        let dataSize  = UInt32(pcmData.count)
        let riffSize  = UInt32(36 + pcmData.count)   // total file - 8-byte RIFF header
        let byteRate  = UInt32(sampleRate * 4)         // sampleRate × blockAlign(4)

        var wav = Data(capacity: 44 + pcmData.count)

        // RIFF header
        wav += "RIFF".utf8
        wav += riffSize.littleEndianBytes
        wav += "WAVE".utf8

        // fmt chunk (16 bytes)
        wav += "fmt ".utf8
        wav += UInt32(16).littleEndianBytes
        wav += UInt16(3).littleEndianBytes          // AudioFormat: IEEE_FLOAT
        wav += UInt16(1).littleEndianBytes          // NumChannels: 1 (mono)
        wav += UInt32(sampleRate).littleEndianBytes
        wav += byteRate.littleEndianBytes
        wav += UInt16(4).littleEndianBytes          // BlockAlign: 4 bytes/frame
        wav += UInt16(32).littleEndianBytes         // BitsPerSample: 32

        // data chunk
        wav += "data".utf8
        wav += dataSize.littleEndianBytes
        wav += pcmData

        return wav
    }

    // MARK: - Private: WAV decode

    /// Walks the RIFF chunk tree and returns the "data" chunk payload.
    static func extractPCM(from wav: Data) -> Data? {
        guard wav.count >= 12,
              wav[0..<4] == Data("RIFF".utf8),
              wav[8..<12] == Data("WAVE".utf8)
        else { return nil }

        var offset = 12
        while offset + 8 <= wav.count {
            let chunkID   = wav[offset ..< offset + 4]
            let chunkSize = wav[(offset + 4) ..< (offset + 8)]
                .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                .littleEndian

            if chunkID == Data("data".utf8) {
                let start = offset + 8
                let end   = min(start + Int(chunkSize), wav.count)
                return wav[start ..< end]
            }

            offset += 8 + Int(chunkSize)
            if chunkSize % 2 != 0 { offset += 1 }   // RIFF pads to even boundary
        }
        return nil
    }

    // MARK: - Private: sidecar model

    private struct SpoolSidecar: Codable {
        let id:              UUID
        let sampleRate:      Int
        let startTime:       Date
        let durationSeconds: Double
        let containsSpeech:  Bool
    }
}

// MARK: - FixedWidthInteger convenience

private extension FixedWidthInteger {
    var littleEndianBytes: Data {
        withUnsafeBytes(of: self.littleEndian) { Data($0) }
    }
}

private extension Data {
    static func += (lhs: inout Data, rhs: String.UTF8View) {
        lhs.append(contentsOf: rhs)
    }
    static func += (lhs: inout Data, rhs: Data) {
        lhs.append(rhs)
    }
}
