import Foundation
import Speech
import AVFoundation

// MARK: - Thread-safe interruption detection state
// Accessed from both the audio render thread (tap callback) and main thread.
// Uses NSLock for safe cross-thread access, following BackgroundAudioManager's pattern.
private let _interruptionLock = NSLock()
private var _isMonitoringForInterruption = false
private var _consecutiveActiveFrames = 0
private let _interruptionEnergyThreshold: Float = -30  // dB, low threshold — AEC removes TTS echo
private let _requiredConsecutiveFrames = 4              // ~85ms at 1024 samples / 48kHz
private var _monitoringStartTime: UInt64 = 0            // mach_absolute_time when monitoring started
private let _monitoringGracePeriodNs: UInt64 = 300_000_000 // 300ms grace period for VP to stabilize

enum SpeechRecognizerError: LocalizedError {
    case notAuthorized
    case notAvailable
    case audioSessionError(Error)
    case recognitionError(Error)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Speech recognition not authorized. Please enable in Settings."
        case .notAvailable:
            return "Speech recognition not available on this device."
        case .audioSessionError(let error):
            return "Audio session error: \(error.localizedDescription)"
        case .recognitionError(let error):
            return "Recognition error: \(error.localizedDescription)"
        }
    }
}

@MainActor
class SpeechRecognizer: ObservableObject {
    @Published var transcribedText = ""
    @Published var isAuthorized = false

    private let speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    // Silence detection for continuous mode
    private var silenceTimer: Timer?
    private var lastTranscriptionTime: Date?
    var onSilenceDetected: (() -> Void)?
    var onRecognitionStopped: (() -> Void)? // called when recognition ends unexpectedly (error or isFinal)
    private var isDeliberatelyStopping = false // suppress onRecognitionStopped during deliberate stops
    var silenceThreshold: TimeInterval = 1.5 // seconds of silence before auto-send

    // 1-minute timeout handling (Apple's limit per recognition task)
    private var recognitionStartTime: Date?
    private var timeoutTimer: Timer?
    private let maxRecognitionDuration: TimeInterval = 55 // restart before 60s limit
    var onTimeoutRestart: (() -> Void)? // callback to restart recognition

    /// When true, the audio engine is kept running even when recognition stops.
    /// iOS does not allow starting new audio I/O from the background, so in
    /// continuous voice mode we keep the engine's mic tap alive and only
    /// stop/restart the speech recognition task.
    var keepEngineRunning = false

    /// Called when voice activity is detected during TTS playback (interruption).
    var onSpeechInterruptionDetected: (() -> Void)?

    /// Whether voice processing (echo cancellation) is currently enabled on the engine.
    private var voiceProcessingEnabled = false

    init() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        checkAuthorization()
    }

    private func checkAuthorization() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                self?.isAuthorized = (status == .authorized)
            }
        }
    }

    func startRecording() async throws {
        isDeliberatelyStopping = false

        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            throw SpeechRecognizerError.notAvailable
        }

        guard isAuthorized else {
            throw SpeechRecognizerError.notAuthorized
        }

        // Cancel any ongoing task
        recognitionTask?.cancel()
        recognitionTask = nil

        let engineAlreadyRunning = audioEngine.isRunning

        // Configure audio session (skip if engine is already running in continuous mode)
        if !engineAlreadyRunning {
            let audioSession = AVAudioSession.sharedInstance()
            do {
                if BackgroundAudioManager.isContinuousVoiceModeActive() {
                    // In continuous voice mode, the audio session is already configured
                    // by BackgroundAudioManager with .voiceChat mode. Don't reconfigure —
                    // changing to .measurement mode in the background triggers !int error.
                    try audioSession.setActive(true)
                } else {
                    try audioSession.setCategory(
                        .playAndRecord,
                        mode: .measurement,
                        options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .duckOthers]
                    )
                    try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
                }
                // Enable hardware echo cancellation for voice interruption support
                if #available(iOS 18.2, *), audioSession.isEchoCancelledInputAvailable {
                    try? audioSession.setPrefersEchoCancelledInput(true)
                }
            } catch {
                throw SpeechRecognizerError.audioSessionError(error)
            }
        }

        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw SpeechRecognizerError.notAvailable
        }

        recognitionRequest.shouldReportPartialResults = true

        // Configure on-device recognition if available (for privacy)
        if #available(iOS 13, *) {
            recognitionRequest.requiresOnDeviceRecognition = false
        }

        // Start recognition task
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                DispatchQueue.main.async {
                    let newText = result.bestTranscription.formattedString
                    if newText != self.transcribedText {
                        self.transcribedText = newText
                        self.lastTranscriptionTime = Date()
                        self.resetSilenceTimer()
                    }
                }
            }

            if error != nil || result?.isFinal == true {
                if !self.keepEngineRunning {
                    self.audioEngine.stop()
                    self.audioEngine.inputNode.removeTap(onBus: 0)
                }
                DispatchQueue.main.async {
                    guard !self.isDeliberatelyStopping else { return }
                    self.onRecognitionStopped?()
                }
            }
        }

        // Configure audio input (skip if engine is already running with a tap)
        if !engineAlreadyRunning {
            let inputNode = audioEngine.inputNode
            inputNode.removeTap(onBus: 0) // Remove any existing tap to avoid duplicate tap crash

            // Enable voice processing for echo cancellation when barge-in is enabled
            // AND output is through built-in speaker (not Bluetooth).
            // VP causes "render err: -1" log noise from Apple's VPIO audio unit when
            // TTS engines run on separate AVAudioEngine instances — this is harmless
            // (AEC still works) but cannot be suppressed from app code.
            // VP may force HFP on Bluetooth (mono phone-call quality), which breaks
            // A2DP car media speaker routing. Skip VP on Bluetooth.
            if VoiceSettingsManager.shared.settings.isVoiceInterruptionEnabled && !voiceProcessingEnabled {
                let route = AVAudioSession.sharedInstance().currentRoute
                let isBluetoothOutput = route.outputs.contains {
                    $0.portType == .bluetoothA2DP || $0.portType == .bluetoothLE || $0.portType == .bluetoothHFP
                }
                if !isBluetoothOutput {
                    do {
                        try inputNode.setVoiceProcessingEnabled(true)
                        voiceProcessingEnabled = true
                        print("[SpeechRecognizer] Voice processing enabled (AEC active)")
                    } catch {
                        print("[SpeechRecognizer] Failed to enable voice processing: \(error)")
                    }
                } else {
                    print("[SpeechRecognizer] Bluetooth output — skipping VP")
                }
            }

            // Get format AFTER VP enabled — VP may change the input node's format
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)

                // VAD: check for user speech during TTS playback
                self?.processBufferForInterruption(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
        }

        transcribedText = ""

        // Start 1-minute timeout timer
        recognitionStartTime = Date()
        startTimeoutTimer()
    }

    // MARK: - Timeout Handling

    private func startTimeoutTimer() {
        timeoutTimer?.invalidate()
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: maxRecognitionDuration, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleTimeout()
            }
        }
    }

    private func stopTimeoutTimer() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
    }

    private func handleTimeout() {
        // Recognition task is approaching 60s limit - need to restart
        // Save current transcription
        let currentText = transcribedText

        // Stop current recognition (deliberate - don't trigger onRecognitionStopped)
        isDeliberatelyStopping = true
        if !keepEngineRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil

        // If we have text, trigger silence detection to send it
        if !currentText.isEmpty {
            onSilenceDetected?()
        } else {
            // No text, just restart
            onTimeoutRestart?()
        }
    }

    func stopRecording() -> String {
        isDeliberatelyStopping = true
        stopSilenceTimer()
        stopTimeoutTimer()

        if !keepEngineRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.reset()
        }

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        recognitionRequest = nil
        recognitionTask = nil
        recognitionStartTime = nil

        if !keepEngineRunning {
            BackgroundAudioManager.deactivateAudioSessionIfAllowed()
        }

        return transcribedText
    }

    /// Fully stop the audio engine. Call when exiting continuous mode
    /// to clean up the engine that was kept alive.
    func stopEngine() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.reset()
        }
        voiceProcessingEnabled = false
    }

    /// Enable or disable voice processing (echo cancellation) at runtime.
    /// Skips enabling VP when Bluetooth is connected (preserves A2DP routing).
    func setVoiceProcessing(enabled: Bool) {
        if enabled {
            let route = AVAudioSession.sharedInstance().currentRoute
            let isBluetoothOutput = route.outputs.contains {
                $0.portType == .bluetoothA2DP || $0.portType == .bluetoothLE || $0.portType == .bluetoothHFP
            }
            if isBluetoothOutput { return }
        }
        guard enabled != voiceProcessingEnabled else { return }
        let wasRunning = audioEngine.isRunning
        if wasRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        do {
            try audioEngine.inputNode.setVoiceProcessingEnabled(enabled)
            voiceProcessingEnabled = enabled
        } catch {
            print("[SpeechRecognizer] Failed to set voice processing: \(error)")
        }
        if wasRunning {
            let recordingFormat = audioEngine.inputNode.outputFormat(forBus: 0)
            audioEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
                self?.processBufferForInterruption(buffer)
            }
            audioEngine.prepare()
            try? audioEngine.start()
        }
    }

    // MARK: - Silence Detection

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceThreshold, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleSilenceDetected()
            }
        }
    }

    private func stopSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = nil
    }

    private func handleSilenceDetected() {
        // Only trigger if we have some transcribed text
        guard !transcribedText.isEmpty else { return }
        onSilenceDetected?()
    }

    /// Start silence detection manually (for continuous mode)
    func startSilenceDetection() {
        lastTranscriptionTime = Date()
        resetSilenceTimer()
    }

    // MARK: - Voice Interruption Detection

    /// Start monitoring the mic tap for speech energy (used during TTS playback).
    /// With voice processing enabled, the mic signal is echo-cancelled (TTS audio subtracted).
    /// Safe to call multiple times — if already monitoring, this is a no-op.
    nonisolated func startInterruptionMonitoring() {
        _interruptionLock.lock()
        if _isMonitoringForInterruption {
            _interruptionLock.unlock()
            return
        }
        _consecutiveActiveFrames = 0
        _monitoringStartTime = mach_absolute_time()
        _isMonitoringForInterruption = true
        _interruptionLock.unlock()
        print("[SpeechRecognizer] Interruption monitoring started")
    }

    /// Stop monitoring for speech interruption.
    nonisolated func stopInterruptionMonitoring() {
        _interruptionLock.lock()
        _isMonitoringForInterruption = false
        _consecutiveActiveFrames = 0
        _interruptionLock.unlock()
    }

    /// Whether interruption monitoring is currently active.
    nonisolated var isInterruptionMonitoringActive: Bool {
        _interruptionLock.lock()
        let active = _isMonitoringForInterruption
        _interruptionLock.unlock()
        return active
    }

    /// Calculate RMS energy and detect sustained speech above threshold.
    /// Runs on the audio render thread — dispatches callback to main.
    /// With voice processing enabled, the buffer contains echo-cancelled audio
    /// (TTS output subtracted), so energy detection is reliable.
    private nonisolated func processBufferForInterruption(_ buffer: AVAudioPCMBuffer) {
        _interruptionLock.lock()
        guard _isMonitoringForInterruption else {
            _interruptionLock.unlock()
            return
        }

        // Short grace period for voice processing to stabilize after monitoring starts
        let elapsed = mach_absolute_time() - _monitoringStartTime
        var timebaseInfo = mach_timebase_info_data_t()
        mach_timebase_info(&timebaseInfo)
        let elapsedNs = elapsed * UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom)
        if elapsedNs < _monitoringGracePeriodNs {
            _interruptionLock.unlock()
            return
        }
        _interruptionLock.unlock()

        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)

        var sum: Float = 0
        for i in 0..<frameLength {
            sum += channelData[0][i] * channelData[0][i]
        }
        let rms = sqrt(sum / Float(frameLength))
        let db = 20 * log10(max(rms, 1e-10))

        _interruptionLock.lock()
        guard _isMonitoringForInterruption else {
            _interruptionLock.unlock()
            return
        }

        if db > _interruptionEnergyThreshold {
            // Fast attack: speech energy detected
            _consecutiveActiveFrames = min(_consecutiveActiveFrames + 2, _requiredConsecutiveFrames + 4)
            if _consecutiveActiveFrames >= _requiredConsecutiveFrames {
                _isMonitoringForInterruption = false
                _consecutiveActiveFrames = 0
                _interruptionLock.unlock()

                print("[SpeechRecognizer] Speech interruption detected (energy: \(String(format: "%.1f", db)) dB)")
                DispatchQueue.main.async { [weak self] in
                    self?.onSpeechInterruptionDetected?()
                }
                return
            }
        } else {
            // Slow decay: speech has natural energy dips between syllables
            _consecutiveActiveFrames = max(0, _consecutiveActiveFrames - 1)
        }
        _interruptionLock.unlock()
    }
}
