import Foundation
import AVFoundation

/// Fish Audio TTS Manager for high-quality cloud-based text-to-speech.
///
/// Uses the Fish Audio streaming API with raw PCM output and
/// `AVAudioEngine` + `AVAudioPlayerNode` for low-latency streaming playback.
///
/// Architecture (modeled after ElevenLabsTTSManager):
/// - `speak()`: Streams PCM chunks from the API and schedules them on the
///   audio player as they arrive — audio starts playing before the full
///   response is received.
/// - `generateAudio()`: Downloads full PCM response and returns an
///   `AVAudioPCMBuffer` — used by IncrementalTTSManager for prefetch.
/// - `playAudioBuffer()`: Plays a pre-generated buffer — used for prefetched audio.
/// - No stored continuations or state machines — completion is tracked inline
///   via `scheduleBuffer` completion handlers, eliminating actor re-entrancy issues.
actor FishAudioTTSManager {
    static let shared = FishAudioTTSManager()

    private let keychainKey = "com.clawdy.fishAudioApiKey"

    /// Shared audio engine (persistent across sentences)
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?

    /// PCM format: 24kHz, mono, Float32 (standard for AVAudioEngine)
    private static let sampleRate: Double = 24000
    private static let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

    /// Chunk size for streaming: 4800 samples = 200ms at 24kHz.
    /// Each Int16 sample is 2 bytes, so 9600 bytes per chunk.
    private static let streamingChunkBytes = 4800 * 2

    // Popular Fish Audio voices
    static let popularVoices: [(id: String, name: String, description: String)] = [
        ("802e3bc2b27e49c2995d23ef70e6ac89", "Energetic Male", "Clear, professional American accent"),
        ("933563129e564b19a115bedd57b7406a", "Sarah", "Soft, conversational female voice"),
        ("bf322df2096a46f18c579d0baa36f41d", "Adrian", "Deep, measured male narrator"),
        ("536d3a5e000945adb7038665781a4aca", "Ethan", "Calm, authoritative male explainer"),
        ("b347db033a6549378b48d00acb0d06cd", "Selene", "Soft, gentle female voice"),
        ("8ef4a238714b45718ce04243307c57a7", "E-girl", "Warm, soothing female voice"),
        ("f772ea09ebe04f66bd3e4a2be1e17329", "Alex", "Expressive male narrator"),
        ("5e79e8f5d2b345f98baa8c83c947532d", "Paddington", "Deep, resonant British narrator"),
    ]

    /// Whether we've already migrated the keychain item this session
    private var didMigrateKeychain = false

    // MARK: - API Key Management

    /// Migrate existing keychain item to use kSecAttrAccessibleAfterFirstUnlock
    /// so the API key is readable when the device is locked (background voice mode).
    private func migrateKeychainAccessibilityIfNeeded() {
        guard !didMigrateKeychain else { return }
        didMigrateKeychain = true

        guard let existingKey = getApiKey() else { return }

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainKey
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainKey,
            kSecValueData as String: existingKey.data(using: .utf8)!,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
        print("[FishAudioTTSManager] Migrated API key to afterFirstUnlock accessibility")
    }

    func saveApiKey(_ key: String) {
        let data = key.data(using: .utf8)!
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainKey
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainKey,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            print("[FishAudioTTSManager] API key saved successfully")
        } else {
            print("[FishAudioTTSManager] Failed to save API key, OSStatus: \(status)")
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
            print("[FishAudioTTSManager] getApiKey failed, OSStatus: \(status)")
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
    }

    var isConfigured: Bool {
        migrateKeychainAccessibilityIfNeeded()
        return getApiKey() != nil
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

        print("[FishAudio] Audio engine set up (24kHz mono Float32)")
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

    /// Build the Fish Audio streaming API request for raw PCM output.
    private func makeStreamingRequest(text: String, referenceId: String, speed: Float) throws -> URLRequest {
        guard let apiKey = getApiKey() else {
            throw FishAudioError.notConfigured
        }

        let url = URL(string: "https://api.fish.audio/v1/tts")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("s1", forHTTPHeaderField: "model")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "text": text,
            "reference_id": referenceId,
            "format": "pcm",
            "sample_rate": 24000,
            "speed": speed,
            "chunk_length": 300,
            "temperature": 0.7,
            "top_p": 0.7
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Validate the HTTP response, throwing descriptive errors for failures.
    private func validateResponse(_ response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FishAudioError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
            }
            if let errorJson = try? JSONSerialization.jsonObject(with: errorData) as? [String: Any],
               let message = errorJson["message"] as? String {
                throw FishAudioError.apiError(message)
            }
            throw FishAudioError.apiError("HTTP \(httpResponse.statusCode)")
        }
    }

    // MARK: - PCM Conversion

    /// Fade-in ramp length: 50ms at 24kHz = 1200 samples.
    private static let fadeInSamples = 1200

    /// Pre-roll silence: 20ms at 24kHz = 480 samples.
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
                channelData[0][i] = Float(Int16(littleEndian: int16Samples[i])) / 32768.0
            }
        }

        return buffer
    }

    /// Apply a linear fade-in ramp to the start of a buffer.
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
        return buffer
    }

    // MARK: - Text-to-Speech (Streaming Playback)

    /// Speak text with true streaming playback.
    func speak(text: String, referenceId: String, speed: Float = 1.0) async throws {
        let request = try makeStreamingRequest(text: text, referenceId: referenceId, speed: speed)

        // Configure audio session — catch errors gracefully so playback can still
        // proceed with whatever session config is already active (e.g. from speech recognizer).
        do {
            let audioSession = AVAudioSession.sharedInstance()
            if BackgroundAudioManager.isContinuousVoiceModeActive() {
                try audioSession.setActive(true)
            } else {
                try audioSession.setCategory(.playAndRecord, mode: .voicePrompt,
                    options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .duckOthers])
                try audioSession.setActive(true)
            }
        } catch {
            print("[FishAudio] Audio session config error (continuing): \(error)")
        }

        try setupAudioEngine()

        guard let player = playerNode, let engine = audioEngine else {
            throw FishAudioError.invalidResponse
        }

        player.stop()

        let volume = await MainActor.run { VoiceSettingsManager.shared.settings.ttsVolume }
        player.volume = volume

        if !engine.isRunning {
            try engine.start()
        }

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try await validateResponse(response, bytes: bytes)

        var pcmData = Data()
        var scheduledCount = 0
        var playerStarted = false

        print("[FishAudio] Streaming PCM audio for: \(text.prefix(40))...")

        for try await byte in bytes {
            if Task.isCancelled { break }
            pcmData.append(byte)

            if pcmData.count >= Self.streamingChunkBytes {
                let chunkData = pcmData.prefix(Self.streamingChunkBytes)
                pcmData = Data(pcmData.dropFirst(Self.streamingChunkBytes))

                if let buffer = convertPCMData(Data(chunkData)) {
                    if !playerStarted {
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

        let finalBuffer: AVAudioPCMBuffer
        if pcmData.count >= 2, let remaining = convertPCMData(pcmData) {
            if !playerStarted {
                applyFadeIn(to: remaining)
            }
            finalBuffer = remaining
        } else {
            finalBuffer = AVAudioPCMBuffer(pcmFormat: Self.pcmFormat, frameCapacity: 1)!
            finalBuffer.frameLength = 1
            finalBuffer.floatChannelData![0][0] = 0
        }

        if !playerStarted {
            player.scheduleBuffer(createPreRollBuffer(), completionHandler: nil)
        }

        scheduledCount += 1
        print("[FishAudio] Streamed \(scheduledCount) chunks, waiting for playback to finish")

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            player.scheduleBuffer(finalBuffer) {
                cont.resume()
            }
            if !playerStarted {
                player.play()
            }
        }

        print("[FishAudio] Playback complete")
    }

    // MARK: - Audio Generation (for Prefetch)

    /// Generate audio from text, returning a complete PCM buffer.
    func generateAudio(text: String, referenceId: String, speed: Float = 1.0) async throws -> AVAudioPCMBuffer {
        let request = try makeStreamingRequest(text: text, referenceId: referenceId, speed: speed)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try await validateResponse(response, bytes: bytes)

        var pcmData = Data()
        for try await byte in bytes {
            pcmData.append(byte)
        }

        print("[FishAudio] Generated \(pcmData.count) bytes of PCM audio")

        guard let buffer = convertPCMData(pcmData) else {
            throw FishAudioError.invalidResponse
        }

        applyFadeIn(to: buffer)

        return buffer
    }

    // MARK: - Buffer Playback (for Prefetch)

    /// Play a pre-generated audio buffer.
    func playAudioBuffer(_ buffer: AVAudioPCMBuffer) async throws {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            if BackgroundAudioManager.isContinuousVoiceModeActive() {
                try audioSession.setActive(true)
            } else {
                try audioSession.setCategory(.playAndRecord, mode: .voicePrompt,
                    options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .duckOthers])
                try audioSession.setActive(true)
            }
        } catch {
            print("[FishAudio] Audio session config error (continuing): \(error)")
        }

        try setupAudioEngine()

        guard let engine = audioEngine, let player = playerNode else {
            throw FishAudioError.invalidResponse
        }

        engine.connect(player, to: engine.mainMixerNode, format: buffer.format)

        let volume = await MainActor.run { VoiceSettingsManager.shared.settings.ttsVolume }
        player.volume = volume

        if !engine.isRunning {
            try engine.start()
        }

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
    func stop() {
        playerNode?.stop()
        teardownAudioEngine()
        BackgroundAudioManager.deactivateAudioSessionIfAllowed()
    }
}

// MARK: - Errors

enum FishAudioError: LocalizedError {
    case notConfigured
    case invalidResponse
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Fish Audio API key not configured"
        case .invalidResponse:
            return "Invalid response from Fish Audio API"
        case .apiError(let message):
            return "Fish Audio API error: \(message)"
        }
    }
}
