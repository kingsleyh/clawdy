import Foundation
import AVFoundation

/// Manages background audio state to allow TTS and voice chat to continue when app enters background.
/// Tracks whether audio is actively playing or continuous voice mode is active
/// to prevent premature app locking and audio session teardown.
@MainActor
class BackgroundAudioManager: ObservableObject {
    // MARK: - Singleton

    static let shared = BackgroundAudioManager()

    // MARK: - Published State

    /// Indicates whether audio is currently playing (TTS or other)
    @Published var isAudioPlaying = false

    /// Indicates whether continuous voice mode is active.
    /// When true, the app maintains its audio session and gateway connection
    /// in the background to allow hands-free voice conversation while using
    /// other apps (e.g. navigation).
    @Published var isContinuousVoiceActive = false

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    /// Call when audio playback starts
    func audioStarted() {
        isAudioPlaying = true
    }

    /// Call when audio playback ends
    func audioEnded() {
        isAudioPlaying = false
    }

    /// Call when continuous voice mode is toggled
    func setContinuousVoiceMode(_ active: Bool) {
        isContinuousVoiceActive = active
        if active {
            // Activate a persistent audio session that supports both input and output.
            // This keeps the app alive in the background via the "audio" background mode.
            // Using .playAndRecord allows simultaneous microphone capture and TTS playback.
            activateBackgroundAudioSession()
        }
    }

    /// Check if the app should lock when entering background.
    /// Returns false if audio is playing or continuous voice mode is active.
    var shouldLockOnBackground: Bool {
        return !isAudioPlaying && !isContinuousVoiceActive
    }

    /// Whether the app should keep its resources (audio engine, gateway connection,
    /// Kokoro model) alive when entering background.
    var shouldKeepAliveInBackground: Bool {
        return isAudioPlaying || isContinuousVoiceActive
    }

    // MARK: - Private Helpers

    /// Activate an audio session configured for background voice chat.
    /// Uses .playAndRecord to support simultaneous mic input and speaker output,
    /// with .defaultToSpeaker so audio comes from the main speaker (not earpiece),
    /// and .allowBluetooth for AirPods / car Bluetooth support.
    private func activateBackgroundAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
            )
            try session.setActive(true)
            print("[BackgroundAudioManager] Activated background voice session (playAndRecord)")
        } catch {
            print("[BackgroundAudioManager] Failed to activate background audio session: \(error)")
        }
    }
}
