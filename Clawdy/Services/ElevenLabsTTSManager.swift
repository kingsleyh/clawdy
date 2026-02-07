import Foundation
import AVFoundation

/// ElevenLabs TTS Manager for high-quality cloud-based text-to-speech.
///
/// Uses the ElevenLabs streaming API (`/v1/text-to-speech/{voice_id}/stream`)
/// with `AVAudioEngine` + `AVAudioPlayerNode` for reliable playback.
///
/// This replaces the previous non-streaming approach that created a new
/// `AVAudioPlayer` per sentence, which caused a race condition where
/// delegate callbacks would fire out of order, leading to repeated audio
/// in continuous mode.
///
/// The streaming approach:
/// 1. Sends text to ElevenLabs streaming endpoint (returns MP3 chunks)
/// 2. Accumulates the full MP3 response
/// 3. Plays via `AVAudioEngine` + `AVAudioPlayerNode` (same pattern as Kokoro)
/// 4. Uses `CheckedContinuation` with proper guarding to prevent double-resume
actor ElevenLabsTTSManager {
    static let shared = ElevenLabsTTSManager()

    private let keychainKey = "com.clawdy.elevenLabsApiKey"

    /// Shared audio engine (persistent, like Kokoro uses)
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?

    /// Guard against double-resume of the playback continuation
    private var playbackContinuation: CheckedContinuation<Void, Error>?

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

        // Update voice settings flag
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

    /// Set up the shared audio engine (reused across sentences)
    private func setupAudioEngine() throws {
        // Reuse existing engine if available
        if audioEngine != nil && playerNode != nil {
            return
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()

        engine.attach(player)

        // Connect player to main mixer with standard format
        let mainMixer = engine.mainMixerNode
        let format = mainMixer.outputFormat(forBus: 0)
        engine.connect(player, to: mainMixer, format: format)

        try engine.start()

        self.audioEngine = engine
        self.playerNode = player

        print("[ElevenLabs] Audio engine set up successfully")
    }

    /// Tear down audio engine
    private func teardownAudioEngine() {
        playerNode?.stop()
        audioEngine?.stop()

        if let player = playerNode, let engine = audioEngine {
            engine.detach(player)
        }

        playerNode = nil
        audioEngine = nil
    }

    // MARK: - Text-to-Speech

    /// Generate audio from text using ElevenLabs streaming API.
    /// Returns the complete audio data (MP3 format).
    func generateAudio(text: String, voiceId: String, speed: Float = 1.0) async throws -> Data {
        guard let apiKey = getApiKey() else {
            throw ElevenLabsError.notConfigured
        }

        // Use streaming endpoint for better reliability
        let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)/stream")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
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

        // Use URLSession bytes for streaming
        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ElevenLabsError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            // Collect error body
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

        // Collect all streamed bytes into a single Data buffer
        var audioData = Data()
        for try await byte in bytes {
            audioData.append(byte)
        }

        print("[ElevenLabs] Received \(audioData.count) bytes of streaming audio")
        return audioData
    }

    /// Speak text using ElevenLabs with streaming API and AVAudioEngine playback.
    ///
    /// This method is safe to call repeatedly — it properly stops any previous
    /// playback and guards against continuation races.
    func speak(text: String, voiceId: String, speed: Float = 1.0) async throws {
        // Cancel any pending continuation from a previous call
        cancelPendingPlayback()

        // Generate audio via streaming API
        let audioData = try await generateAudio(text: text, voiceId: voiceId, speed: speed)

        // Play the audio
        try await playAudioData(audioData)
    }

    /// Play MP3 audio data using AVAudioEngine + AVAudioPlayerNode.
    ///
    /// Uses the same reliable playback pattern as Kokoro TTS:
    /// - Shared persistent audio engine
    /// - Proper completion callback via `scheduleBuffer` completion handler
    /// - Guarded continuation to prevent double-resume
    private func playAudioData(_ data: Data) async throws {
        print("[ElevenLabs] Playing audio data: \(data.count) bytes")

        // Stop any existing playback first
        cancelPendingPlayback()

        // Configure audio session
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback, mode: .voicePrompt,
            options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try audioSession.setActive(true)

        // Set up audio engine if needed
        try setupAudioEngine()

        guard let engine = audioEngine, let player = playerNode else {
            throw ElevenLabsError.invalidResponse
        }

        // Decode MP3 data to PCM buffer
        guard let audioBuffer = try Self.decodeMp3ToPCM(data: data, engine: engine) else {
            throw ElevenLabsError.invalidResponse
        }

        print("[ElevenLabs] Decoded to PCM buffer: \(audioBuffer.frameLength) frames, \(audioBuffer.format.sampleRate) Hz")

        // Play using checked continuation with proper guarding
        return try await withCheckedThrowingContinuation { continuation in
            self.playbackContinuation = continuation

            // Stop player before scheduling new buffer
            player.stop()

            // Schedule the buffer with completion callback
            player.scheduleBuffer(audioBuffer) { [weak self] in
                Task { [weak self] in
                    await self?.handlePlaybackFinished()
                }
            }

            // Start playback
            if !engine.isRunning {
                do {
                    try engine.start()
                } catch {
                    self.playbackContinuation = nil
                    continuation.resume(throwing: error)
                    return
                }
            }

            player.play()
            print("[ElevenLabs] Started playback via AVAudioEngine")
        }
    }

    /// Decode MP3 data to a PCM buffer suitable for AVAudioEngine playback.
    private static func decodeMp3ToPCM(data: Data, engine: AVAudioEngine) throws -> AVAudioPCMBuffer? {
        // Write MP3 data to a temporary file for AVAudioFile to read
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp3")

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        try data.write(to: tempURL)

        // Read MP3 file
        let audioFile = try AVAudioFile(forReading: tempURL)
        let processingFormat = audioFile.processingFormat
        let frameCount = UInt32(audioFile.length)

        guard frameCount > 0 else { return nil }

        // Read into a buffer matching the file's processing format
        guard let fileBuffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: frameCount) else {
            return nil
        }
        try audioFile.read(into: fileBuffer)

        // Convert to the engine's output format if needed
        let outputFormat = engine.mainMixerNode.outputFormat(forBus: 0)

        if processingFormat == outputFormat {
            return fileBuffer
        }

        // Create a converter
        guard let converter = AVAudioConverter(from: processingFormat, to: outputFormat) else {
            // If conversion fails, return the original buffer and hope the engine handles it
            return fileBuffer
        }

        // Estimate output frame count
        let ratio = outputFormat.sampleRate / processingFormat.sampleRate
        let outputFrameCount = UInt32(Double(frameCount) * ratio)

        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) else {
            return fileBuffer
        }

        var error: NSError?
        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return fileBuffer
        }

        if let error = error {
            print("[ElevenLabs] Audio conversion error: \(error)")
            return fileBuffer
        }

        return convertedBuffer
    }

    /// Handle playback completion — resume the continuation exactly once.
    private func handlePlaybackFinished() {
        let cont = playbackContinuation
        playbackContinuation = nil
        cont?.resume()
        print("[ElevenLabs] Playback finished via AVAudioEngine")
    }

    /// Cancel any pending playback and resume its continuation with cancellation.
    private func cancelPendingPlayback() {
        playerNode?.stop()

        if let cont = playbackContinuation {
            playbackContinuation = nil
            cont.resume(throwing: CancellationError())
            print("[ElevenLabs] Cancelled pending playback")
        }
    }

    /// Stop current playback and tear down.
    func stop() {
        cancelPendingPlayback()
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
