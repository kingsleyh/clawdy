import SwiftUI
import AVFoundation
import FluidAudio

/// View for managing known speakers — enroll new speakers, rename, and delete.
struct SpeakerManagementView: View {
    @StateObject private var diarizationManager = SpeakerDiarizationManager.shared
    @State private var isEnrolling = false
    @State private var enrollmentName = ""
    @State private var isRecording = false
    @State private var recordingStartTime: Date?
    @State private var recordingProgress: Double = 0
    @State private var hasRecording = false
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var editingSpeakerId: String?
    @State private var editingName = ""
    @State private var isSaving = false

    @State private var audioRecorder: AVAudioRecorder?

    // SwiftUI-native timer for progress — guaranteed to update @State on main thread
    private let progressTimer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    private let enrollmentDuration: TimeInterval = 5.0

    private var recordingURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("enrollment_sample.wav")
    }

    var body: some View {
        List {
            // Model status
            if !diarizationManager.isModelReady {
                Section {
                    if diarizationManager.isDownloadingModels {
                        HStack {
                            ProgressView()
                                .padding(.trailing, 8)
                            Text("Downloading diarization models...")
                        }
                    } else {
                        Button("Download Speaker Models") {
                            Task {
                                do {
                                    try await diarizationManager.prepareModels()
                                } catch {
                                    statusMessage = "Failed to download models: \(error.localizedDescription)"
                                    statusIsError = true
                                }
                            }
                        }
                    }
                } header: {
                    Text("Setup")
                } footer: {
                    Text("Speaker identification requires on-device AI models (~50MB). Download once to get started.")
                }
            }

            // Known speakers
            Section {
                if diarizationManager.knownSpeakers.isEmpty {
                    Text("No enrolled speakers")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(diarizationManager.knownSpeakers, id: \.id) { speaker in
                        speakerRow(speaker)
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            let speaker = diarizationManager.knownSpeakers[index]
                            diarizationManager.removeSpeaker(id: speaker.id)
                        }
                    }
                }
            } header: {
                Text("Known Speakers")
            } footer: {
                Text("Enrolled speakers will be recognized by name during conversations.")
            }

            // Enroll new speaker
            Section {
                if isEnrolling {
                    enrollmentFormContent
                } else {
                    Button {
                        isEnrolling = true
                        enrollmentName = ""
                        hasRecording = false
                        statusMessage = nil
                        statusIsError = false
                    } label: {
                        Label("Enroll New Speaker", systemImage: "person.badge.plus")
                    }
                    .disabled(!diarizationManager.isModelReady)
                }
            } header: {
                Text("Enrollment")
            } footer: {
                Text("Record a 5-second voice sample to teach Clawdy to recognize a speaker by name.")
            }
        }
        .navigationTitle("Speaker Identification")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(progressTimer) { _ in
            guard isRecording, let start = recordingStartTime else { return }
            let elapsed = Date().timeIntervalSince(start)
            recordingProgress = min(elapsed / enrollmentDuration, 1.0)
            if elapsed >= enrollmentDuration + 0.3 {
                finishRecording()
            }
        }
    }

    // MARK: - Subviews

    private func speakerRow(_ speaker: Speaker) -> some View {
        HStack {
            Image(systemName: "person.circle.fill")
                .foregroundColor(.accentColor)
                .font(.title2)
            VStack(alignment: .leading) {
                if editingSpeakerId == speaker.id {
                    TextField("Name", text: $editingName, onCommit: {
                        diarizationManager.renameSpeaker(id: speaker.id, newName: editingName)
                        editingSpeakerId = nil
                    })
                    .textFieldStyle(.roundedBorder)
                } else {
                    Text(speaker.name)
                        .font(.body)
                }
            }
            Spacer()
            if editingSpeakerId != speaker.id {
                Button {
                    editingSpeakerId = speaker.id
                    editingName = speaker.name
                } label: {
                    Image(systemName: "pencil")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var enrollmentFormContent: some View {
        TextField("Speaker Name", text: $enrollmentName)
            .textFieldStyle(.roundedBorder)

        // Status / error
        if let msg = statusMessage {
            Label(msg, systemImage: statusIsError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.caption)
                .foregroundColor(statusIsError ? .red : .secondary)
        }

        // Recording in progress
        if isRecording {
            VStack(spacing: 8) {
                ProgressView(value: recordingProgress)
                    .progressViewStyle(.linear)
                Label(
                    "Recording... speak now (\(Int(recordingProgress * enrollmentDuration))s / \(Int(enrollmentDuration))s)",
                    systemImage: "mic.fill"
                )
                .font(.caption)
                .foregroundColor(.red)
            }
        }

        // Recording complete
        if hasRecording && !isRecording {
            Label("Voice sample recorded", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundColor(.green)
        }

        // Saving spinner
        if isSaving {
            HStack {
                ProgressView()
                    .padding(.trailing, 4)
                Text("Processing voice sample...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }

        // Action buttons
        if !isRecording && !hasRecording && !isSaving {
            Button {
                startRecording()
            } label: {
                Label("Record Voice Sample", systemImage: "mic.circle.fill")
            }
            .disabled(enrollmentName.trimmingCharacters(in: .whitespaces).isEmpty)
        }

        if hasRecording && !isRecording && !isSaving {
            Button("Save Speaker") {
                saveEnrollment()
            }
            .buttonStyle(.borderedProminent)
            .disabled(enrollmentName.trimmingCharacters(in: .whitespaces).isEmpty)

            Button("Re-record") {
                hasRecording = false
                statusMessage = nil
                startRecording()
            }
        }

        Button("Cancel", role: .cancel) {
            cancelEnrollment()
        }
    }

    // MARK: - Recording

    private func startRecording() {
        statusMessage = nil
        statusIsError = false
        hasRecording = false

        let audioSession = AVAudioSession.sharedInstance()
        do {
            if !BackgroundAudioManager.isContinuousVoiceModeActive() {
                try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            }
            try audioSession.setActive(true)
        } catch {
            print("[Enrollment] Audio session error: \(error)")
            statusMessage = "Audio error: \(error.localizedDescription)"
            statusIsError = true
            return
        }

        try? FileManager.default.removeItem(at: recordingURL)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 48000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        do {
            let recorder = try AVAudioRecorder(url: recordingURL, settings: settings)
            recorder.record(forDuration: enrollmentDuration)
            audioRecorder = recorder
            recordingStartTime = Date()
            isRecording = true
            recordingProgress = 0
            print("[Enrollment] Recording started")
        } catch {
            print("[Enrollment] Recorder error: \(error)")
            statusMessage = "Recording failed: \(error.localizedDescription)"
            statusIsError = true
        }
    }

    private func finishRecording() {
        audioRecorder?.stop()
        audioRecorder = nil
        recordingStartTime = nil
        isRecording = false
        hasRecording = true
        print("[Enrollment] Recording finished, progress: \(recordingProgress)")
    }

    private func saveEnrollment() {
        let name = enrollmentName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        isSaving = true
        statusMessage = nil
        statusIsError = false

        Task {
            do {
                let audioFile = try AVAudioFile(forReading: recordingURL)
                let format = audioFile.processingFormat
                let frameCount = AVAudioFrameCount(audioFile.length)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                    throw NSError(domain: "Enrollment", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create buffer"])
                }
                try audioFile.read(into: buffer)
                print("[Enrollment] Read \(buffer.frameLength) frames (\(format.sampleRate) Hz)")

                try await diarizationManager.enrollSpeaker(audioBuffer: buffer, name: name)
                print("[Enrollment] Speaker '\(name)' enrolled successfully")

                // Reset enrollment UI
                cancelEnrollment()
            } catch {
                print("[Enrollment] Save failed: \(error)")
                await MainActor.run {
                    statusMessage = "Enrollment failed: \(error.localizedDescription)"
                    statusIsError = true
                    isSaving = false
                }
            }
        }
    }

    private func cancelEnrollment() {
        audioRecorder?.stop()
        audioRecorder = nil
        try? FileManager.default.removeItem(at: recordingURL)
        isEnrolling = false
        isRecording = false
        hasRecording = false
        isSaving = false
        enrollmentName = ""
        statusMessage = nil
        statusIsError = false
        recordingProgress = 0
        recordingStartTime = nil
    }
}
