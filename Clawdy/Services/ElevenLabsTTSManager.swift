import Foundation
import AVFoundation

/// ElevenLabs TTS Manager for high-quality cloud-based text-to-speech.
///
/// Uses the ElevenLabs streaming API with raw PCM output (`pcm_24000`) and
/// `AVAudioEngine` + `AVAudioPlayerNode` for low-latency streaming playback.
///
/// Architecture (modeled after KokoroTTSManager):
/// - `speak()`: Streams PCM chunks from the API and schedules them on the
///   audio player as they arrive — audio starts playing before the full
///   response is received.
/// - `generateAudio()`: Downloads full PCM response and returns an
///   `AVAudioPCMBuffer` — used by IncrementalTTSManager for prefetch.
/// - `playAudioBuffer()`: Plays a pre-generated buffer — used for prefetched audio.
/// - No stored continuations or state machines — completion is tracked inline
///   via `scheduleBuffer` completion handlers, eliminating actor re-entrancy issues.
actor ElevenLabsTTSManager {
    static let shared = ElevenLabsTTSManager()

    private let keychainKey = "com.clawdy.elevenLabsApiKey"

    /// Shared audio engine (persistent across sentences)
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?

    /// PCM format: 24kHz, mono, Float32 (standard for AVAudioEngine)
    private static let sampleRate: Double = 24000
    private static let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

    /// Chunk size for streaming: 4800 samples = 200ms at 24kHz.
    /// Each Int16 sample is 2 bytes, so 9600 bytes per chunk.
    private static let streamingChunkBytes = 4800 * 2

    // Popular ElevenLabs voices
    static let popularVoices: [(id: String, name: String, description: String)] = [
        ("EXAVITQu4vr4xnSDxMaL", "Sarah", "Warm, friendly female voice"),
        ("21m00Tcm4TlvDq8ikWAM", "Rachel", "Clear, professional female voice"),
        ("AZnzlk1XvdvUeBnXmlld", "Domi", "Strong, confident female voice"),
        ("IKne3meq5aSn9XLyUdCD", "Charlie", "Natural, casual male voice"),
        ("TX3LPaxmHKxFdv7VOQHJ", "Liam", "Young, energetic male voice"),
        ("pNInz6obpgDQGcFmaJgB", "Adam", "Deep, authoritative male voice"),
        ("ThT5KcBeYPX3keUQqHPh", "Dorothy", "Warm, soothing female voice"),
        ("VR6AewLTigWG4xSOukaG", "Arnold", "Strong, confident male voice"),
    ]

    // MARK: - API Key Management

    func saveApiKey(_ key: String) {
        let data = key.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainKey,
            kSecValueData as String: data
        ]

        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)

        Task { @MainActor in
            VoiceSettingsManager.shared.settings.elevenLabsConfigured = true
        }
    }

    func getApiKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }

        return key
    }

    func deleteApiKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainKey
        ]
        SecItemDelete(query as CFDictionary)

        Task { @MainActor in
            VoiceSettingsManager.shared.settings.elevenLabsConfigured = false
        }
    }

    var isConfigured: Bool {
        getApiKey() != nil
    }

    // MARK: - Audio Engine Setup

    /// Set up the shared audio engine with PCM format.
    private func setupAudioEngine() throws {
        if audioEngine != nil && playerNode != nil {
            return
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: Self.pcmFormat)
        try engine.start()

        self.audioEngine = engine
        self.playerNode = player

        print("[ElevenLabs] Audio engine set up (24kHz mono Float32)")
    }

    /// Tear down audio engine and release resources.
    private func teardownAudioEngine() {
        playerNode?.stop()
        audioEngine?.stop()

        if let player = playerNode, let engine = audioEngine {
            engine.detach(player)
        }

        playerNode = nil
        audioEngine = nil
    }

    // MARK: - API Request

    /// Build the ElevenLabs streaming API request for raw PCM output.
    private func makeStreamingRequest(text: String, voiceId: String, speed: Float) throws -> URLRequest {
        guard let apiKey = getApiKey() else {
            throw ElevenLabsError.notConfigured
        }

        let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)/stream?output_format=pcm_24000")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_turbo_v2_5",
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75,
                "style": 0.0,
                "use_speaker_boost": true
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Validate the HTTP response, throwing descriptive errors for failures.
    private func validateResponse(_ response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ElevenLabsError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
            }
            if let errorJson = try? JSONSerialization.jsonObject(with: errorData) as? [String: Any],
               let detail = errorJson["detail"] as? [String: Any],
               let message = detail["message"] as? String {
                throw ElevenLabsError.apiError(message)
            }
            throw ElevenLabsError.apiError("HTTP \(httpResponse.statusCode)")
        }
    }

    // MARK: - PCM Conversion

    /// Fade-in ramp length: 50ms at 24kHz = 1200 samples.
    /// Eliminates the click/pop from silence → audio transition on the first buffer.
    private static let fadeInSamples = 1200

    /// Pre-roll silence: 20ms at 24kHz = 480 samples.
    /// Scheduled before the first real audio to let the audio hardware settle
    /// after engine start, preventing the startup transient/pop.
    private static let preRollSamples: AVAudioFrameCount = 480

    /// Convert raw Int16 little-endian PCM data to an AVAudioPCMBuffer (Float32).
    private func convertPCMData(_ data: Data) -> AVAudioPCMBuffer? {
        let sampleCount = data.count / 2  // 2 bytes per Int16 sample
        guard sampleCount > 0 else { return nil }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: Self.pcmFormat, frameCapacity: AVAudioFrameCount(sampleCount)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(sampleCount)

        guard let channelData = buffer.floatChannelData else { return nil }

        data.withUnsafeBytes { rawBuffer in
            let int16Samples = rawBuffer.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                // Int16 LE to Float32: divide by 32768 to normalize to [-1.0, 1.0]
                channelData[0][i] = Float(Int16(littleEndian: int16Samples[i])) / 32768.0
            }
        }

        return buffer
    }

    /// Apply a linear fade-in ramp to the start of a buffer.
    /// Smoothly ramps from silence to full volume over `fadeInSamples` samples,
    /// preventing the click/pop that occurs when audio starts at a non-zero value.
    private func applyFadeIn(to buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let rampLength = min(Int(buffer.frameLength), Self.fadeInSamples)
        guard rampLength > 0 else { return }

        let rampLengthFloat = Float(rampLength)
        for i in 0..<rampLength {
            let gain = Float(i) / rampLengthFloat
            channelData[0][i] *= gain
        }
    }

    /// Create a silent pre-roll buffer to let the audio hardware settle after engine start.
    private func createPreRollBuffer() -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: Self.pcmFormat, frameCapacity: Self.preRollSamples)!
        buffer.frameLength = Self.preRollSamples
        // Buffer is zero-initialized by default — all silence
        return buffer
    }

    // MARK: - Text-to-Speech (Streaming Playback)

    /// Speak text with true streaming playback.
    ///
    /// PCM chunks are scheduled on the audio player as they arrive from the API,
    /// so audio starts playing before the full response is received.
    func speak(text: String, voiceId: String, speed: Float = 1.0) async throws {
        let request = try makeStreamingRequest(text: text, voiceId: voiceId, speed: speed)

        // Configure audio session
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback, mode: .voicePrompt,
            options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try audioSession.setActive(true)

        // Set up audio engine
        try setupAudioEngine()

        guard let player = playerNode, let engine = audioEngine else {
            throw ElevenLabsError.invalidResponse
        }

        // Stop any previous playback
        player.stop()

        // Start engine (but NOT the player yet — wait for first chunk to avoid empty-player pop)
        if !engine.isRunning {
            try engine.start()
        }

        // Stream PCM bytes from the API
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try await validateResponse(response, bytes: bytes)

        var pcmData = Data()
        var scheduledCount = 0
        var playerStarted = false

        print("[ElevenLabs] Streaming PCM audio for: \(text.prefix(40))...")

        for try await byte in bytes {
            if Task.isCancelled { break }
            pcmData.append(byte)

            // Schedule a buffer every ~200ms of audio
            if pcmData.count >= Self.streamingChunkBytes {
                let chunkData = pcmData.prefix(Self.streamingChunkBytes)
                pcmData = Data(pcmData.dropFirst(Self.streamingChunkBytes))

                if let buffer = convertPCMData(Data(chunkData)) {
                    if !playerStarted {
                        // First chunk ready — schedule pre-roll silence + faded-in audio, then start.
                        // Must use completionHandler: overload (synchronous) — the no-handler
                        // overload is async and waits for playback, deadlocking a stopped player.
                        player.scheduleBuffer(createPreRollBuffer(), completionHandler: nil)
                        applyFadeIn(to: buffer)
                        player.scheduleBuffer(buffer, completionHandler: nil)
                        player.play()
                        playerStarted = true
                    } else {
                        player.scheduleBuffer(buffer, completionHandler: nil)
                    }
                    scheduledCount += 1
                }
            }
        }

        guard !Task.isCancelled else { return }

        // Schedule remaining data with completion handler to know when playback finishes.
        let finalBuffer: AVAudioPCMBuffer
        if pcmData.count >= 2, let remaining = convertPCMData(pcmData) {
            // If player never started (very short audio), apply full startup sequence
            if !playerStarted {
                applyFadeIn(to: remaining)
            }
            finalBuffer = remaining
        } else {
            // Sentinel: 1 silent sample so the completion handler fires after all prior buffers
            finalBuffer = AVAudioPCMBuffer(pcmFormat: Self.pcmFormat, frameCapacity: 1)!
            finalBuffer.frameLength = 1
            finalBuffer.floatChannelData![0][0] = 0
        }

        // Start player if it hasn't started yet (short audio that fit in one chunk)
        if !playerStarted {
            player.scheduleBuffer(createPreRollBuffer(), completionHandler: nil)
        }

        scheduledCount += 1
        print("[ElevenLabs] Streamed \(scheduledCount) chunks, waiting for playback to finish")

        // Wait for all scheduled buffers to play through.
        // The completion handler fires after this buffer (the last one) finishes.
        // Captured inline — no stored continuation, no actor re-entrancy.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            player.scheduleBuffer(finalBuffer) {
                cont.resume()
            }
            if !playerStarted {
                player.play()
            }
        }

        print("[ElevenLabs] Playback complete")
    }

    // MARK: - Audio Generation (for Prefetch)

    /// Generate audio from text, returning a complete PCM buffer.
    ///
    /// Used by IncrementalTTSManager for prefetching the next sentence's audio
    /// while the current sentence is still playing.
    func generateAudio(text: String, voiceId: String, speed: Float = 1.0) async throws -> AVAudioPCMBuffer {
        let request = try makeStreamingRequest(text: text, voiceId: voiceId, speed: speed)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try await validateResponse(response, bytes: bytes)

        // Collect all PCM data
        var pcmData = Data()
        for try await byte in bytes {
            pcmData.append(byte)
        }

        print("[ElevenLabs] Generated \(pcmData.count) bytes of PCM audio")

        guard let buffer = convertPCMData(pcmData) else {
            throw ElevenLabsError.invalidResponse
        }

        // Fade in to prevent click when this buffer starts playback
        applyFadeIn(to: buffer)

        return buffer
    }

    // MARK: - Buffer Playback (for Prefetch)

    /// Play a pre-generated audio buffer.
    ///
    /// Matches KokoroTTSManager.playAudioBuffer() API for use with
    /// IncrementalTTSManager's prefetch pipeline.
    func playAudioBuffer(_ buffer: AVAudioPCMBuffer) async throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback, mode: .voicePrompt,
            options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try audioSession.setActive(true)

        try setupAudioEngine()

        guard let engine = audioEngine, let player = playerNode else {
            throw ElevenLabsError.invalidResponse
        }

        engine.connect(player, to: engine.mainMixerNode, format: buffer.format)

        if !engine.isRunning {
            try engine.start()
        }

        // Schedule pre-roll silence BEFORE starting the player.
        // Uses completionHandler: overload (synchronous) — the no-handler overload is async
        // and waits for playback to finish, deadlocking a stopped player.
        player.scheduleBuffer(createPreRollBuffer(), completionHandler: nil)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            player.scheduleBuffer(buffer) {
                cont.resume()
            }
            player.play()
        }
    }

    // MARK: - Stop

    /// Stop current playback and tear down.
    ///
    /// Stopping the player node triggers any pending `scheduleBuffer` completion
    /// handlers, which resume any awaiting continuations naturally.
    func stop() {
        playerNode?.stop()
        teardownAudioEngine()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - Errors

enum ElevenLabsError: LocalizedError {
    case notConfigured
    case invalidResponse
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "ElevenLabs API key not configured"
        case .invalidResponse:
            return "Invalid response from ElevenLabs API"
        case .apiError(let message):
            return "ElevenLabs API error: \(message)"
        }
    }
}
