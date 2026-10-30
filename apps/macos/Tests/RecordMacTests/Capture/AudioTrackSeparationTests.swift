@preconcurrency import AVFoundation
import CoreMedia
import XCTest
@testable import RecordMac

/// Microphone and system audio go to distinct writer inputs and files, each holding only its own
/// source's samples (FR-017). This drives the writer side; routing from a live stream is
/// verified with the capture backend.
final class AudioTrackSeparationTests: XCTestCase {
    func testMicrophoneAndSystemAudioAreWrittenApartAndNeverMixed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("separation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writers = AudioSourceWriters(sources: [.microphone, .systemAudio], start: .zero) {
            directory.appendingPathComponent("\($0.rawValue).mov")
        }
        let micFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44_100, channels: 1, interleaved: true))
        let systemFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
        var micBytes = Data()
        var systemBytes = Data()
        for packet in 0..<5 {
            let (mic, micData) = try AudioFixtures.buffer(format: micFormat, frames: 4410, start: Double(packet) / 10, seed: 11)
            let (system, systemData) = try AudioFixtures.buffer(format: systemFormat, frames: 4800, start: Double(packet) / 10, seed: 57)
            writers.append(mic, from: .microphone)
            writers.append(system, from: .systemAudio)
            micBytes.append(micData)
            systemBytes.append(systemData)
        }
        let results = await writers.finish()

        let micWriter = try XCTUnwrap(writers.writer(for: .microphone))
        let systemWriter = try XCTUnwrap(writers.writer(for: .systemAudio))
        XCTAssertNotEqual(micWriter.url, systemWriter.url)
        let micInput = try XCTUnwrap(micWriter.writerInput)
        let systemInput = try XCTUnwrap(systemWriter.writerInput)
        XCTAssertFalse(micInput === systemInput, "each source has its own writer input")

        XCTAssertEqual(results[.microphone]?.written, .decoded(22_050))
        XCTAssertEqual(results[.systemAudio]?.written, .decoded(24_000))
        let micFile = try await AudioFixtures.read(micWriter.url)
        let systemFile = try await AudioFixtures.read(systemWriter.url)
        XCTAssertEqual(micFile.format.mSampleRate, 44_100)
        XCTAssertEqual(micFile.format.mChannelsPerFrame, 1)
        XCTAssertEqual(systemFile.format.mSampleRate, 48_000)
        XCTAssertEqual(systemFile.format.mChannelsPerFrame, 2)
        XCTAssertEqual(micFile.bytes, micBytes, "the microphone file holds only microphone samples")
        XCTAssertEqual(systemFile.bytes, systemBytes, "the system audio file holds only system samples")
    }
}
