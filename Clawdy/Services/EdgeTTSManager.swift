import Foundation
import AVFoundation
import CryptoKit

/// Edge TTS Manager for free Microsoft Edge text-to-speech.
/// Uses Microsoft's Bing speech service via WebSocket — no API key required.
actor EdgeTTSManager {
    static let shared = EdgeTTSManager()

    private var audioPlayer: AVAudioPlayer?

    // MARK: - Constants

    private static let chromiumVersion = "143.0.3650.75"
    private static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private static let windowsFileTimeEpoch: Int64 = 11_644_473_600

    // MARK: - Popular Voices

    static let popularVoices: [(id: String, name: String, gender: String, description: String)] = [
        ("en-US-JennyNeural", "Jenny", "Female", "Warm, friendly American"),
        ("en-US-GuyNeural", "Guy", "Male", "Casual, natural American"),
        ("en-US-AriaNeural", "Aria", "Female", "Clear, professional American"),
        ("en-US-DavisNeural", "Davis", "Male", "Deep, confident American"),
        ("en-US-AndrewNeural", "Andrew", "Male", "Young, energetic American"),
        ("en-US-MichelleNeural", "Michelle", "Female", "Warm, expressive American"),
        ("en-US-RogerNeural", "Roger", "Male", "Authoritative American"),
        ("en-US-SteffanNeural", "Steffan", "Male", "Smooth, professional American"),
        ("en-GB-SoniaNeural", "Sonia", "Female", "Elegant British"),
        ("en-GB-RyanNeural", "Ryan", "Male", "Natural British"),
        ("en-AU-NatashaNeural", "Natasha", "Female", "Friendly Australian"),
    ]

    // MARK: - DRM Token

    private static func generateSecMsGecToken() -> String {
        let currentTime = Int64(Date().timeIntervalSince1970)
        let ticks = (currentTime + windowsFileTimeEpoch) * 10_000_000
        let roundedTicks = ticks - (ticks % 3_000_000_000)

        let strToHash = "\(roundedTicks)\(trustedClientToken)"
        guard let data = strToHash.data(using: .ascii) else { return "" }

        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02X", $0) }.joined()
    }

    // MARK: - Speed Mapping

    /// Convert Float speed multiplier to Edge TTS rate string.
    /// 1.0 → "+0%", 1.5 → "+50%", 0.75 → "-25%"
    private static func speedToRate(_ speed: Float) -> String {
        let percentage = Int((speed - 1.0) * 100)
        return "\(percentage >= 0 ? "+" : "")\(percentage)%"
    }

    // MARK: - Text-to-Speech

    /// Generate audio data from text using Edge TTS.
    func generateAudio(text: String, voiceId: String, speed: Float = 1.0) async throws -> Data {
        let token = Self.generateSecMsGecToken()
        let urlString = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1?TrustedClientToken=\(Self.trustedClientToken)&Sec-MS-GEC=\(token)&Sec-MS-GEC-Version=1-\(Self.chromiumVersion)"

        guard let url = URL(string: urlString) else {
            throw EdgeTTSError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(Self.chromiumVersion) Safari/537.36 Edg/\(Self.chromiumVersion)",
            forHTTPHeaderField: "User-Agent")
        request.setValue(
            "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold",
            forHTTPHeaderField: "Origin")

        let delegate = WebSocketDelegate()
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let webSocket = session.webSocketTask(with: request)
        webSocket.resume()

        // Wait for WebSocket connection to open
        try await delegate.waitForConnection()

        // Send configuration
        let configMessage = "Content-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n{\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":{\"sentenceBoundaryEnabled\":\"false\",\"wordBoundaryEnabled\":\"false\"},\"outputFormat\":\"audio-24khz-48kbitrate-mono-mp3\"}}}}"
        try await webSocket.send(.string(configMessage))

        // Send SSML request
        let requestId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let rate = Self.speedToRate(speed)
        let escapedText = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")

        let ssml = "X-RequestId:\(requestId)\r\nContent-Type:application/ssml+xml\r\nPath:ssml\r\n\r\n<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"\(voiceId)\"><prosody rate=\"\(rate)\" pitch=\"+0Hz\" volume=\"+0%\">\(escapedText)</prosody></voice></speak>"
        try await webSocket.send(.string(ssml))

        // Collect audio data
        var audioData = Data()

        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await webSocket.receive()
            } catch {
                // Connection closed — return what we have
                break
            }

            switch message {
            case .data(let data):
                // Binary messages have a 2-byte big-endian header length prefix,
                // followed by the text header, followed by audio data.
                guard data.count > 2 else { continue }
                let headerLen = Int(data[0]) << 8 | Int(data[1])
                let audioStart = 2 + headerLen
                guard audioStart < data.count else { continue }
                // Verify this is an audio message by checking the header
                let headerData = data.subdata(in: 2..<audioStart)
                if let header = String(data: headerData, encoding: .utf8),
                   header.contains("Path:audio") {
                    audioData.append(data.subdata(in: audioStart..<data.count))
                }

            case .string(let str):
                if str.contains("Path:turn.end") {
                    // Done
                    break
                }
                // Ignore metadata messages
                continue

            @unknown default:
                continue
            }

            // Check if we got turn.end
            if case .string(let str) = message, str.contains("Path:turn.end") {
                break
            }
        }

        webSocket.cancel(with: .goingAway, reason: nil)

        guard !audioData.isEmpty else {
            throw EdgeTTSError.noAudioData
        }

        return audioData
    }

    /// Speak text using Edge TTS.
    func speak(text: String, voiceId: String, speed: Float = 1.0) async throws {
        let audioData = try await generateAudio(text: text, voiceId: voiceId, speed: speed)
        let volume = await MainActor.run { VoiceSettingsManager.shared.settings.ttsVolume }

        print("[EdgeTTS] Playing audio data: \(audioData.count) bytes")

        return try await withCheckedThrowingContinuation { continuation in
            do {
                let audioSession = AVAudioSession.sharedInstance()
                if BackgroundAudioManager.isContinuousVoiceModeActive() {
                    try audioSession.setActive(true)
                } else {
                    try audioSession.setCategory(.playback, mode: .voicePrompt,
                        options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
                    try audioSession.setActive(true)
                }


                let player = try AVAudioPlayer(data: audioData)
                self.audioPlayer = player

                let delegate = EdgeAudioPlayerDelegate {
                    continuation.resume()
                }
                player.delegate = delegate
                objc_setAssociatedObject(player, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)

                player.volume = volume
                player.play()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Stop current playback.
    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        BackgroundAudioManager.deactivateAudioSessionIfAllowed()
    }
}

// MARK: - Errors

enum EdgeTTSError: LocalizedError {
    case invalidURL
    case connectionFailed
    case noAudioData
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Edge TTS URL"
        case .connectionFailed:
            return "Failed to connect to Edge TTS service"
        case .noAudioData:
            return "No audio data received from Edge TTS"
        case .apiError(let message):
            return "Edge TTS error: \(message)"
        }
    }
}

// MARK: - WebSocket Delegate

private final class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?
    private let lock = NSLock()

    func waitForConnection() async throws {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            continuation = cont
            lock.unlock()
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        if let error = error {
            cont?.resume(throwing: error)
        }
    }
}

// MARK: - Audio Player Delegate

private class EdgeAudioPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        onFinish()
    }
}
