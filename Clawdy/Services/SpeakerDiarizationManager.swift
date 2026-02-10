import Foundation
import AVFoundation
import FluidAudio
import CoreML

/// Manages on-device speaker diarization and voice identification using FluidAudio.
///
/// Responsibilities:
/// - Download/load diarization models (Pyannote segmentation + WeSpeaker embeddings)
/// - Run batch diarization on recorded audio
/// - Match detected speakers against stored profiles
/// - Persist known speaker profiles to disk
@MainActor
class SpeakerDiarizationManager: ObservableObject {
    static let shared = SpeakerDiarizationManager()

    // MARK: - Published State

    @Published var isModelReady = false
    @Published var isDownloadingModels = false
    @Published var knownSpeakers: [Speaker] = []

    // MARK: - Private State

    private var diarizer: DiarizerManager?
    private var models: DiarizerModels?
    private let speakersFileURL: URL

    /// Cosine similarity threshold for manual re-matching unknown speakers.
    /// Lower = more permissive (more likely to match). Range: 0.0–1.0.
    private let rematchThreshold: Float = 0.45

    /// Weight for blending new embeddings into stored profiles (0.0–1.0).
    /// Higher = new observations have more influence.
    private let embeddingUpdateWeight: Float = 0.15

    // MARK: - Init

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        speakersFileURL = docs.appendingPathComponent("known_speakers.json")
        loadSpeakers()
    }

    // MARK: - Model Lifecycle

    /// Download models if needed and initialize the diarizer.
    func prepareModels() async throws {
        guard !isModelReady else { return }

        isDownloadingModels = true
        defer { isDownloadingModels = false }

        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine

        let loadedModels = try await DiarizerModels.downloadIfNeeded(configuration: config)
        models = loadedModels

        let diarizerConfig = DiarizerConfig(
            clusteringThreshold: 0.50, // Lower threshold for better known-speaker matching
            minSpeechDuration: 0.8,
            debugMode: false
        )
        let manager = DiarizerManager(config: diarizerConfig)
        manager.initialize(models: loadedModels)

        // Initialize with known speakers so they're recognized by name
        if !knownSpeakers.isEmpty {
            manager.initializeKnownSpeakers(knownSpeakers)
        }

        diarizer = manager
        isModelReady = true
        print("[SpeakerDiarization] Models ready, \(knownSpeakers.count) known speakers loaded")
    }

    // MARK: - Diarization

    /// Result of diarization for a speech segment.
    struct DiarizedMessage {
        /// The original transcription text
        let originalText: String
        /// Formatted text with speaker labels (only if multiple speakers)
        let labeledText: String
        /// Names of all speakers detected
        let speakerNames: [String]
        /// Whether multiple speakers were detected
        let isMultiSpeaker: Bool
    }

    /// Diarize audio and correlate with transcribed text.
    ///
    /// - Parameters:
    ///   - audioBuffer: Raw PCM audio buffer from the microphone
    ///   - transcription: The speech-to-text result for this audio
    /// - Returns: Diarized message with speaker labels
    func diarize(audioBuffer: AVAudioPCMBuffer, transcription: String) async throws -> DiarizedMessage {
        guard let diarizer = diarizer else {
            throw DiarizerError.notInitialized
        }

        // Convert to 16kHz mono Float32 as required by FluidAudio
        let samples = try convertTo16kHzMono(audioBuffer)
        guard samples.count > 1600 else { // At least 0.1s of audio
            return DiarizedMessage(
                originalText: transcription,
                labeledText: transcription,
                speakerNames: [],
                isMultiSpeaker: false
            )
        }

        let result = try diarizer.performCompleteDiarization(samples, sampleRate: 16000)

        // Re-match unknown speakers against known profiles using cosine similarity.
        // FluidAudio's internal matching can miss when the clustering threshold
        // assigns a new cluster ID instead of matching an existing speaker.
        let remappedSegments = rematchUnknownSpeakers(segments: result.segments, diarizer: diarizer)

        // Collect unique speakers (using remapped IDs)
        var speakerIds = Set<String>()
        for segment in remappedSegments {
            speakerIds.insert(segment.speakerId)
        }

        let speakerNames = speakerIds.sorted().map { id -> String in
            if let speaker = diarizer.speakerManager.getSpeaker(for: id) {
                return speaker.name
            }
            // Check our local known speakers too (in case speakerManager doesn't have it)
            if let speaker = knownSpeakers.first(where: { $0.id == id }) {
                return speaker.name
            }
            return id
        }

        // If only one speaker, no labels needed
        if speakerIds.count <= 1 {
            let name = speakerNames.first ?? "Unknown"

            // Auto-update embedding if the speaker was confidently matched
            if let knownSpeaker = knownSpeakers.first(where: { $0.name == name }),
               let bestSegment = longestSegment(in: remappedSegments) {
                updateSpeakerEmbedding(speaker: knownSpeaker, newEmbedding: bestSegment.embedding)
            }

            return DiarizedMessage(
                originalText: transcription,
                labeledText: transcription,
                speakerNames: [name],
                isMultiSpeaker: false
            )
        }

        // Multiple speakers — format with labels
        let labeled = formatMultiSpeakerText(
            segments: remappedSegments,
            transcription: transcription,
            totalDuration: Float(samples.count) / 16000.0,
            diarizer: diarizer
        )

        // Update known speakers from diarizer's speaker database
        updateKnownSpeakersFromResult(diarizer: diarizer)

        return DiarizedMessage(
            originalText: transcription,
            labeledText: labeled,
            speakerNames: speakerNames,
            isMultiSpeaker: true
        )
    }

    // MARK: - Re-matching Unknown Speakers

    /// Check segments with unknown speaker IDs against known speaker embeddings.
    /// Returns segments with speaker IDs remapped where a match was found.
    private func rematchUnknownSpeakers(segments: [TimedSpeakerSegment], diarizer: DiarizerManager) -> [TimedSpeakerSegment] {
        guard !knownSpeakers.isEmpty else { return segments }

        // Build set of known speaker IDs in the diarizer
        let knownIds = Set(knownSpeakers.map { $0.id })

        var remapped = segments
        for i in 0..<remapped.count {
            let segment = remapped[i]

            // Skip if already matched to a known speaker
            if knownIds.contains(segment.speakerId) { continue }
            if diarizer.speakerManager.getSpeaker(for: segment.speakerId) != nil,
               knownSpeakers.contains(where: { $0.id == segment.speakerId }) {
                continue
            }

            // Try manual cosine similarity match against known speakers
            let embedding = segment.embedding
            guard !embedding.isEmpty else { continue }

            var bestMatch: (speaker: Speaker, similarity: Float)?
            for known in knownSpeakers {
                let sim = cosineSimilarity(embedding, known.currentEmbedding)
                if sim > rematchThreshold {
                    if bestMatch == nil || sim > bestMatch!.similarity {
                        bestMatch = (known, sim)
                    }
                }
            }

            if let match = bestMatch {
                print("[SpeakerDiarization] Re-matched '\(segment.speakerId)' → '\(match.speaker.name)' (similarity: \(String(format: "%.3f", match.similarity)))")
                remapped[i] = TimedSpeakerSegment(
                    speakerId: match.speaker.id,
                    embedding: segment.embedding,
                    startTimeSeconds: segment.startTimeSeconds,
                    endTimeSeconds: segment.endTimeSeconds,
                    qualityScore: segment.qualityScore
                )
            }
        }

        return remapped
    }

    /// Cosine similarity between two embedding vectors.
    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }

    /// Get the longest segment (most speech content).
    private func longestSegment(in segments: [TimedSpeakerSegment]) -> TimedSpeakerSegment? {
        segments.max(by: {
            ($0.endTimeSeconds - $0.startTimeSeconds) < ($1.endTimeSeconds - $1.startTimeSeconds)
        })
    }

    // MARK: - Embedding Auto-Update

    /// Blend a new observation into the speaker's stored embedding (exponential moving average).
    /// This gradually adapts the profile to the speaker's voice in different conditions.
    private func updateSpeakerEmbedding(speaker: Speaker, newEmbedding: [Float]) {
        guard speaker.currentEmbedding.count == newEmbedding.count else { return }

        var updated = [Float](repeating: 0, count: newEmbedding.count)
        for i in 0..<updated.count {
            updated[i] = (1 - embeddingUpdateWeight) * speaker.currentEmbedding[i] + embeddingUpdateWeight * newEmbedding[i]
        }

        // L2-normalize the blended embedding
        let norm = sqrt(updated.reduce(0) { $0 + $1 * $1 })
        if norm > 0 {
            for i in 0..<updated.count {
                updated[i] /= norm
            }
        }

        speaker.currentEmbedding = updated

        // Re-initialize in diarizer with updated embedding
        diarizer?.initializeKnownSpeakers([speaker])

        saveSpeakers()
    }

    // MARK: - Speaker Enrollment

    /// Enroll a new speaker from a voice sample.
    ///
    /// - Parameters:
    ///   - audioBuffer: PCM audio of the speaker (5+ seconds recommended)
    ///   - name: Name to associate with this voice
    /// - Returns: The created Speaker
    @discardableResult
    func enrollSpeaker(audioBuffer: AVAudioPCMBuffer, name: String) async throws -> Speaker {
        guard let diarizer = diarizer else {
            throw DiarizerError.notInitialized
        }

        let samples = try convertTo16kHzMono(audioBuffer)
        let result = try diarizer.performCompleteDiarization(samples, sampleRate: 16000)

        // Take the dominant speaker's embedding
        guard let bestSegment = result.segments.max(by: {
            ($0.endTimeSeconds - $0.startTimeSeconds) < ($1.endTimeSeconds - $1.startTimeSeconds)
        }) else {
            throw DiarizerError.processingFailed("No speaker detected in enrollment audio")
        }

        let speaker = Speaker(
            name: name,
            currentEmbedding: bestSegment.embedding,
            isPermanent: true
        )

        // Add to diarizer's known speakers
        diarizer.initializeKnownSpeakers([speaker])

        // Persist
        knownSpeakers.append(speaker)
        saveSpeakers()

        print("[SpeakerDiarization] Enrolled speaker '\(name)' with \(bestSegment.embedding.count)-dim embedding")
        return speaker
    }

    /// Remove a known speaker by ID.
    func removeSpeaker(id: String) {
        knownSpeakers.removeAll { $0.id == id }
        diarizer?.speakerManager.removeSpeaker(id, keepIfPermanent: false)
        saveSpeakers()
    }

    /// Rename a known speaker.
    func renameSpeaker(id: String, newName: String) {
        if let speaker = knownSpeakers.first(where: { $0.id == id }) {
            speaker.name = newName
            saveSpeakers()
        }
    }

    // MARK: - Audio Conversion

    /// Convert AVAudioPCMBuffer to 16kHz mono Float32 array.
    private func convertTo16kHzMono(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        guard let channelData = buffer.floatChannelData else {
            throw DiarizerError.invalidAudioData
        }

        let frameCount = Int(buffer.frameLength)
        let sampleRate = buffer.format.sampleRate
        let channelCount = Int(buffer.format.channelCount)

        // Mix to mono if stereo
        var monoSamples = [Float](repeating: 0, count: frameCount)
        if channelCount == 1 {
            memcpy(&monoSamples, channelData[0], frameCount * MemoryLayout<Float>.size)
        } else {
            for i in 0..<frameCount {
                var sum: Float = 0
                for ch in 0..<channelCount {
                    sum += channelData[ch][i]
                }
                monoSamples[i] = sum / Float(channelCount)
            }
        }

        // Resample to 16kHz if needed
        if abs(sampleRate - 16000) < 1 {
            return monoSamples
        }

        let ratio = 16000.0 / sampleRate
        let outputCount = Int(Double(frameCount) * ratio)
        var resampled = [Float](repeating: 0, count: outputCount)
        for i in 0..<outputCount {
            let srcIndex = Double(i) / ratio
            let srcIndexInt = Int(srcIndex)
            let frac = Float(srcIndex - Double(srcIndexInt))
            if srcIndexInt + 1 < frameCount {
                resampled[i] = monoSamples[srcIndexInt] * (1 - frac) + monoSamples[srcIndexInt + 1] * frac
            } else if srcIndexInt < frameCount {
                resampled[i] = monoSamples[srcIndexInt]
            }
        }

        return resampled
    }

    // MARK: - Multi-Speaker Formatting

    /// Format transcription with speaker labels based on diarization segments.
    ///
    /// Since we only have the full transcription (not word-level timestamps),
    /// we approximate speaker turns by proportional text splitting based on
    /// diarization segment durations.
    private func formatMultiSpeakerText(
        segments: [TimedSpeakerSegment],
        transcription: String,
        totalDuration: Float,
        diarizer: DiarizerManager
    ) -> String {
        guard !segments.isEmpty, totalDuration > 0 else { return transcription }

        // Group consecutive segments by speaker
        var turns: [(speakerId: String, startTime: Float, endTime: Float)] = []
        for segment in segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
            if let last = turns.last, last.speakerId == segment.speakerId {
                turns[turns.count - 1].endTime = segment.endTimeSeconds
            } else {
                turns.append((segment.speakerId, segment.startTimeSeconds, segment.endTimeSeconds))
            }
        }

        // If only one turn, no labeling needed
        if turns.count <= 1 {
            return transcription
        }

        // Split transcription proportionally by turn duration
        let words = transcription.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return transcription }

        let totalTurnDuration = turns.reduce(Float(0)) { $0 + ($1.endTime - $1.startTime) }
        var result = ""
        var wordIndex = 0

        for (i, turn) in turns.enumerated() {
            let turnDuration = turn.endTime - turn.startTime
            let turnRatio = turnDuration / max(totalTurnDuration, 0.001)
            let wordCount: Int
            if i == turns.count - 1 {
                wordCount = words.count - wordIndex
            } else {
                wordCount = max(1, Int(round(Float(words.count) * turnRatio)))
            }

            let endWord = min(wordIndex + wordCount, words.count)
            let turnText = words[wordIndex..<endWord].joined(separator: " ")
            wordIndex = endWord

            let speakerName: String
            if let speaker = diarizer.speakerManager.getSpeaker(for: turn.speakerId) {
                speakerName = speaker.name
            } else if let speaker = knownSpeakers.first(where: { $0.id == turn.speakerId }) {
                speakerName = speaker.name
            } else {
                speakerName = turn.speakerId
            }

            if !result.isEmpty { result += "\n" }
            result += "[\(speakerName)]: \(turnText)"

            if wordIndex >= words.count { break }
        }

        return result
    }

    // MARK: - Persistence

    private func saveSpeakers() {
        do {
            let data = try JSONEncoder().encode(knownSpeakers)
            try data.write(to: speakersFileURL)
            print("[SpeakerDiarization] Saved \(knownSpeakers.count) speakers")
        } catch {
            print("[SpeakerDiarization] Failed to save speakers: \(error)")
        }
    }

    private func loadSpeakers() {
        guard FileManager.default.fileExists(atPath: speakersFileURL.path) else { return }
        do {
            let data = try Data(contentsOf: speakersFileURL)
            knownSpeakers = try JSONDecoder().decode([Speaker].self, from: data)
            print("[SpeakerDiarization] Loaded \(knownSpeakers.count) known speakers")
        } catch {
            print("[SpeakerDiarization] Failed to load speakers: \(error)")
        }
    }

    /// Update known speakers list from the diarizer's internal speaker database.
    /// New permanent speakers (enrolled) are preserved; transient speakers are skipped.
    private func updateKnownSpeakersFromResult(diarizer: DiarizerManager) {
        let allSpeakers = diarizer.speakerManager.getSpeakerList()
        for speaker in allSpeakers where speaker.isPermanent {
            if !knownSpeakers.contains(where: { $0.id == speaker.id }) {
                knownSpeakers.append(speaker)
            }
        }
        saveSpeakers()
    }
}
