import SwiftUI
import PhotosUI
import UIKit

struct ContentView: View {
    @StateObject private var viewModel = ClawdyViewModel()
    @StateObject private var imagePickerCoordinator = ImagePickerCoordinator()
    @State private var showingSettings = false

    /// Focus state for text input - used to dismiss/show keyboard on mode switch
    @FocusState private var isTextFieldFocused: Bool

    /// Selected items from PhotosPicker (processed and cleared after selection)
    @State private var selectedPhotoItems: [PhotosPickerItem] = []

    /// Captured image from camera (processed and cleared after capture)
    @State private var capturedImage: UIImage? = nil

    /// Whether the app is currently offline (gateway disconnected)
    /// Note: Partial connections with chat capability are considered "online" for messaging
    private var isOffline: Bool {
        // Consider offline if disconnected or partialNode (no chat capability)
        switch viewModel.connectionStatus {
        case .disconnected, .partialNode(_):
            return true
        case .connected, .partialOperator(_, _), .connecting, .pairingPending(_, _):
            return false
        }
    }

    /// Whether chat functionality is available (connected or partial with chat)
    private var canChat: Bool {
        viewModel.connectionStatus.canChat
    }

    var body: some View {
        VStack(spacing: 0) {
            // Status bar with settings button
            StatusBarView(
                connectionStatus: viewModel.connectionStatus,
                gatewayFailure: viewModel.gatewayFailure,
                vpnStatus: viewModel.vpnStatus,
                onSettingsTap: { showingSettings = true }
            )

            // Offline banner (shown when disconnected)
            if isOffline && !viewModel.isReconnecting {
                OfflineBannerView(
                    connectionStatus: viewModel.connectionStatus,
                    gatewayFailure: viewModel.gatewayFailure,
                    isReconnecting: viewModel.isReconnecting,
                    onRetry: {
                        Task {
                            await viewModel.triggerReconnection()
                        }
                    }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Reconnecting indicator (smaller, during active reconnection)
            if viewModel.isReconnecting {
                ConnectionStatusBadge(
                    status: viewModel.connectionStatus,
                    isReconnecting: viewModel.isReconnecting
                )
                .padding(.vertical, 8)
                .transition(.opacity)
            }

            // Transcript area with image support
            TranscriptView(
                messages: viewModel.messages,
                streamingMessage: viewModel.streamingMessage,
                imageStore: viewModel.imageStore,
                onImageTap: { attachment in
                    viewModel.showImageFullScreen(attachment, allIds: viewModel.messages.flatMap { $0.imageAttachmentIds })
                }
            )

            Spacer()

            // Processing state indicator (thinking, tool use, responding)
            // Note: Streaming text now displays directly in TranscriptView via streamingMessage
            if viewModel.processingState.isActive {
                ProcessingIndicatorView(
                    state: viewModel.processingState,
                    onCancel: {
                        viewModel.abortGeneration()
                    },
                    isCancelling: viewModel.isAborting
                )
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // Input area: voice mode or text mode with transition animations
            Group {
                if viewModel.inputMode == .voice {
                    // Voice input with mic button, continuous mode toggle, and keyboard toggle
                    HStack(alignment: .bottom, spacing: 16) {
                        Spacer()

                        // Continuous mode toggle button (positioned to the left of mic)
                        VStack {
                            Spacer()
                            ContinuousModeToggleButton(
                                isEnabled: viewModel.isContinuousMode,
                                onTap: {
                                    viewModel.toggleContinuousMode()
                                }
                            )
                            .padding(.bottom, 8)
                        }
                        .frame(height: 80)

                        MicButtonView(
                            isRecording: viewModel.isRecording,
                            isSpeaking: viewModel.isSpeaking,
                            isGeneratingAudio: viewModel.isGeneratingAudio,
                            processingState: viewModel.processingState,
                            isContinuousMode: viewModel.isContinuousMode,
                            onTap: {
                                if viewModel.isContinuousMode {
                                    // In continuous mode, tapping stops the mode
                                    viewModel.toggleContinuousMode()
                                } else if viewModel.isRecording {
                                    viewModel.stopRecording()
                                } else if viewModel.isSpeaking {
                                    viewModel.stopSpeaking()
                                } else {
                                    viewModel.startRecording()
                                }
                            },
                            onLongPress: {
                                // Long press to abort generation
                                if viewModel.processingState.isActive {
                                    viewModel.abortGeneration()
                                }
                            }
                        )

                        // Keyboard toggle button (positioned to the right of mic)
                        VStack {
                            Spacer()
                            TextModeToggleButton {
                                viewModel.inputMode = .text
                            }
                            .padding(.bottom, 8)
                        }
                        .frame(height: 80)

                        Spacer()
                    }
                    .padding(.bottom, 40)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.8).combined(with: .opacity),
                        removal: .scale(scale: 0.8).combined(with: .opacity)
                    ))
                } else {
                    // Text input mode with image attachment support
                    TextInputBar(
                        text: $viewModel.textInput,
                        pendingImages: $viewModel.pendingImages,
                        onSend: { viewModel.sendTextInput() },
                        onSwitchToVoice: {
                            // Dismiss keyboard before switching to voice mode
                            isTextFieldFocused = false
                            viewModel.inputMode = .voice
                        },
                        onPhotoLibrary: {
                            imagePickerCoordinator.handleMenuSelection(.photoLibrary)
                        },
                        onCamera: {
                            imagePickerCoordinator.handleMenuSelection(.camera)
                        },
                        onRemoveImage: { id in
                            viewModel.removePendingImage(id)
                        },
                        isEnabled: !isOffline && !viewModel.processingState.isActive,
                        isFocused: $isTextFieldFocused
                    )
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                    ))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: viewModel.inputMode)
        }
        .background(Color(.systemBackground))
        .animation(.easeInOut(duration: 0.2), value: viewModel.processingState)
        .animation(.easeInOut(duration: 0.3), value: isOffline)
        .animation(.easeInOut(duration: 0.3), value: viewModel.isReconnecting)
        .animation(.easeInOut(duration: 0.25), value: viewModel.inputMode)
        .sheet(isPresented: $showingSettings) {
            SettingsView(onClearContext: {
                viewModel.clearContext()
            })
        }
        .overlay(alignment: .bottom) {
            // Toast notification overlay
            if let message = viewModel.toastMessage {
                ToastView(message: message, icon: "checkmark.circle.fill")
                    .padding(.bottom, 100)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.3), value: viewModel.toastMessage)
            }
        }
        .overlay {
            // Camera flash overlay for camera.snap feedback
            // This provides visual feedback similar to iOS camera shutter effect
            if viewModel.showingCameraFlash {
                CameraFlashOverlay()
                    .transition(.opacity)
                    .animation(.easeOut(duration: 0.15), value: viewModel.showingCameraFlash)
            }
        }
        .overlay {
            if viewModel.authTokenMissing {
                AuthTokenBlockingView {
                    showingSettings = true
                }
            }
        }
        .onChange(of: showingSettings) { _, isPresented in
            // Reconnect when settings is dismissed (credentials may have changed)
            if !isPresented {
                Task {
                    await viewModel.connect()
                }
            }
        }
        .onChange(of: viewModel.inputMode) { _, newMode in
            // Auto-focus text field when switching to text mode
            if newMode == .text {
                // Small delay to allow view transition to complete before focusing
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isTextFieldFocused = true
                }
            }
        }
        // MARK: - Image Attachment Modifiers

        // Photo library picker with dynamic max selection based on current pending count
        .photosPicker(
            isPresented: $imagePickerCoordinator.showingPhotoPicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: viewModel.maxImagesPerMessage - viewModel.pendingImages.count,
            matching: .images
        )
        // Process selected photos from picker
        .onChange(of: selectedPhotoItems) { _, items in
            Task {
                await viewModel.addImages(from: items)
                selectedPhotoItems = []
            }
        }
        // Camera view for taking photos
        .fullScreenCover(isPresented: $imagePickerCoordinator.showingCamera) {
            CameraView(capturedImage: $capturedImage)
        }
        // Process captured image from camera
        .onChange(of: capturedImage) { _, image in
            if let image = image {
                Task {
                    await viewModel.addImage(from: image)
                    capturedImage = nil
                }
            }
        }
        // Permission alerts for camera and photo library access
        .permissionAlert($imagePickerCoordinator.permissionAlert)
        // Quick Look full-screen image viewer
        .fullScreenCover(isPresented: $viewModel.showingQuickLook) {
            QuickLookView(
                imageURLs: viewModel.quickLookImages,
                initialIndex: viewModel.quickLookIndex
            )
        }
    }
}

// MARK: - Status Bar View

struct StatusBarView: View {
    let connectionStatus: ConnectionStatus
    let gatewayFailure: GatewayConnectionFailure
    let vpnStatus: VPNStatus
    let onSettingsTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Gateway connection status indicator
            ConnectionStatusIndicator(status: connectionStatus)

            Divider()
                .frame(height: 24)
                .accessibilityHidden(true)

            // VPN status indicator - only show warning when VPN is needed
            VPNStatusIndicator(
                status: vpnStatus,
                showWarning: shouldShowVPNWarning
            )

            if shouldShowVPNSettingsShortcut {
                Button(action: openVPNSettings) {
                    Text("Open VPN Settings")
                        .font(.caption2)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Open VPN Settings")
                .accessibilityHint("Opens VPN settings")
            }

            Spacer()

            Button(action: onSettingsTap) {
                Image(systemName: "gearshape")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
            .accessibilityLabel("Settings")
            .accessibilityHint("Double tap to open settings")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status bar")
    }

    /// Whether we should show VPN as a warning (disconnected AND needed due to host unreachable)
    private var shouldShowVPNWarning: Bool {
        guard vpnStatus == .disconnected else { return false }
        guard case .disconnected = connectionStatus else { return false }
        guard case .hostUnreachable = gatewayFailure else { return false }
        return true
    }

    private var shouldShowVPNSettingsShortcut: Bool {
        guard shouldShowVPNWarning else { return false }
        return canOpenVPNSettings
    }

    private var canOpenVPNSettings: Bool {
        if let vpnURL = URL(string: "App-Prefs:root=VPN"), UIApplication.shared.canOpenURL(vpnURL) {
            return true
        }
        if let settingsURL = URL(string: UIApplication.openSettingsURLString),
           UIApplication.shared.canOpenURL(settingsURL) {
            return true
        }
        return false
    }

    private func openVPNSettings() {
        if let vpnURL = URL(string: "App-Prefs:root=VPN"), UIApplication.shared.canOpenURL(vpnURL) {
            UIApplication.shared.open(vpnURL)
            return
        }
        if let settingsURL = URL(string: UIApplication.openSettingsURLString),
           UIApplication.shared.canOpenURL(settingsURL) {
            UIApplication.shared.open(settingsURL)
        }
    }
}

// MARK: - VPN Status Indicator

struct VPNStatusIndicator: View {
    let status: VPNStatus
    /// Whether to show VPN disconnected as a warning (red).
    /// When false and VPN is disconnected, shows neutral/gray state.
    var showWarning: Bool = true

    var body: some View {
        HStack(spacing: 6) {
            // Status dot
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)

            // Status text
            VStack(alignment: .leading, spacing: 1) {
                Text(statusTitle)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)

                if let subtitle = statusSubtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        switch status {
        case .connected(let interfaceName):
            return "VPN connected via \(interfaceName)"
        case .disconnected:
            return showWarning ? "VPN disconnected, may be needed" : "VPN not connected"
        case .unknown:
            return "VPN status unknown"
        }
    }

    private var statusColor: Color {
        switch status {
        case .connected:
            return .green
        case .disconnected:
            // Only show red if VPN is actually needed (showWarning)
            return showWarning ? .red : .gray
        case .unknown:
            return .gray
        }
    }

    private var statusTitle: String {
        switch status {
        case .connected:
            return "VPN"
        case .disconnected:
            return "No VPN"
        case .unknown:
            return "VPN"
        }
    }

    private var statusSubtitle: String? {
        switch status {
        case .connected(let interfaceName):
            return interfaceName
        case .disconnected:
            // Don't show "Disconnected" subtitle when VPN isn't needed
            return showWarning ? "Disconnected" : nil
        case .unknown:
            return "Checking..."
        }
    }
}

// MARK: - Connection Status Indicator

struct CapabilityBadge: View {
    let label: String
    let status: ConnectionCapabilities.RoleStatus

    var body: some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
            Image(systemName: iconName)
                .font(.system(size: 8, weight: .semibold))
        }
        .foregroundColor(statusColor)
    }

    private var iconName: String {
        switch status {
        case .connected:
            return "checkmark"
        case .disconnected:
            return "xmark"
        case .pairingPending:
            return "clock"
        }
    }

    private var statusColor: Color {
        switch status {
        case .connected:
            return .green
        case .disconnected:
            return .secondary
        case .pairingPending:
            return .yellow
        }
    }
}

struct CapabilityStatusLine: View {
    let capabilities: ConnectionCapabilities

    var body: some View {
        HStack(spacing: 8) {
            CapabilityBadge(label: "Chat", status: capabilities.chat)
            CapabilityBadge(label: "Node", status: capabilities.node)
        }
    }
}

struct ConnectionStatusIndicator: View {
    let status: ConnectionStatus
    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 6) {
            // Animated status dot
            ZStack {
                // Pulse animation for connecting state
                if case .connecting = status {
                    Circle()
                        .fill(status.color.opacity(0.3))
                        .frame(width: 16, height: 16)
                        .scaleEffect(isPulsing ? 1.5 : 1.0)
                        .opacity(isPulsing ? 0 : 0.5)
                }

                Circle()
                    .fill(status.color)
                    .frame(width: 10, height: 10)
            }
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)

            // Status text
            VStack(alignment: .leading, spacing: 2) {
                Text("Gateway")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)

                if let capabilities = status.capabilities {
                    CapabilityStatusLine(capabilities: capabilities)
                } else if let subtitle = statusSubtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .onAppear {
            startPulsingIfNeeded()
        }
        .onChange(of: status) { _, newStatus in
            startPulsingIfNeeded()
        }
    }

    private var statusSubtitle: String? {
        switch status {
        case .connected(let serverName):
            return "Connected • \(serverName)"
        case .connecting:
            return "Connecting..."
        case .disconnected(let reason):
            return reason
        case .partialOperator(let serverName, let nodeStatus):
            let nodeDetail = nodeStatus == .pairingPending ? "node pairing" : "node unavailable"
            return "Partial • \(nodeDetail) • \(serverName)"
        case .partialNode(let chatStatus):
            let chatDetail = chatStatus == .pairingPending ? "chat pairing" : "chat unavailable"
            return "Partial • \(chatDetail)"
        case .pairingPending(_, _):
            return "Pairing..."
        }
    }

    private var accessibilityDescription: String {
        status.accessibilityDescription
    }

    private func startPulsingIfNeeded() {
        if shouldPulse {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        } else {
            isPulsing = false
        }
    }

    private var shouldPulse: Bool {
        switch status {
        case .connecting:
            return true
        case .partialOperator(_, let nodeStatus):
            return nodeStatus == .pairingPending
        case .partialNode(let chatStatus):
            return chatStatus == .pairingPending
        case .pairingPending(_, _):
            return true
        case .connected, .disconnected:
            return false
        }
    }
}

// MARK: - Transcript View

struct TranscriptView: View {
    let messages: [TranscriptMessage]
    /// The currently streaming message being received from the gateway (live updates)
    let streamingMessage: TranscriptMessage?

    /// Image store for resolving image attachment IDs to actual images
    let imageStore: ImageAttachmentStore

    /// Callback when an image thumbnail is tapped in a message (for Quick Look)
    let onImageTap: (ImageAttachment) -> Void

    /// ID of the bottom anchor for scroll tracking
    private let bottomAnchorID = "bottom_anchor"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { message in
                        MessageBubble(
                            message: message,
                            imageStore: imageStore,
                            onImageTap: onImageTap
                        )
                        .id(message.id)
                    }

                    // Show the streaming message at the end of the list if it exists
                    // Use "streaming_" prefix to ensure different view identity from finalized messages
                    if let streaming = streamingMessage {
                        MessageBubble(
                            message: streaming,
                            imageStore: imageStore,
                            onImageTap: onImageTap
                        )
                        .id("streaming_\(streaming.id)")
                    }

                    // Invisible bottom anchor for scroll position tracking
                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchorID)
                }
                .padding()
            }
            .onChange(of: messages.count) { _, _ in
                scrollToBottom(proxy)
                if let lastMessage = messages.last {
                    // Announce new message for VoiceOver users
                    let announcement = lastMessage.isUser
                        ? "Message sent"
                        : "Claude responded"
                    UIAccessibility.post(notification: .announcement, argument: announcement)
                }
            }
            // Auto-scroll when streaming message first appears
            .onChange(of: streamingMessage != nil) { _, isStreaming in
                if isStreaming {
                    scrollToBottom(proxy)
                }
            }
            // Follow streaming updates as they arrive
            .onChange(of: streamingMessage?.text ?? "") { _, _ in
                scrollToBottom(proxy)
            }
        }
        .accessibilityLabel("Conversation transcript")
        .accessibilityHint(messages.isEmpty ? "No messages yet" : "\(messages.count) messages")
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
    }
}

struct MessageBubble: View {
    let message: TranscriptMessage

    /// Image store for resolving image attachment IDs to actual images
    let imageStore: ImageAttachmentStore

    /// Callback when an image thumbnail is tapped (for Quick Look full-screen view)
    let onImageTap: (ImageAttachment) -> Void

    var body: some View {
        VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
            Text(message.isUser ? "You" : "Clawdy")
                .font(.caption)
                .foregroundColor(.secondary)
                .accessibilityHidden(true) // Included in combined label below

            // Message content with optional images and inline tool calls
            VStack(alignment: .leading, spacing: 8) {
                // Images first (iMessage style - images appear above text)
                if !message.imageAttachmentIds.isEmpty {
                    MessageImageGrid(
                        attachmentIds: message.imageAttachmentIds,
                        imageStore: imageStore,
                        onTap: onImageTap
                    )
                }

                // Main message text
                if !message.text.isEmpty {
                    Text(message.text)
                        .foregroundColor(message.isUser ? .white : .primary)
                }

                // Inline tool calls (only for Claude's messages)
                if !message.isUser && !message.toolCalls.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(message.toolCalls) { toolCall in
                            CollapsibleToolCallView(toolCall: toolCall)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(message.isUser ? Color.blue : Color(.secondarySystemBackground))
            .cornerRadius(16)
            .overlay(
                // Pulsing border for streaming messages
                StreamingBorderOverlay(isStreaming: message.isStreaming)
            )
        }
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Builds an accessibility label that includes message text, images, and tool call summary
    private var accessibilityLabel: String {
        var label = message.isUser ? "You said" : "Claude said"

        // Include image count if present
        let imageCount = message.imageAttachmentIds.count
        if imageCount > 0 {
            label += " with \(imageCount) image\(imageCount == 1 ? "" : "s")"
        }

        if !message.text.isEmpty {
            label += ": \(message.text)"
        }

        if !message.toolCalls.isEmpty {
            let toolNames = message.toolCalls.map { $0.name }.joined(separator: ", ")
            let toolCount = message.toolCalls.count
            label += ". Used \(toolCount) tool\(toolCount == 1 ? "" : "s"): \(toolNames)"
        }

        return label
    }
}

// MARK: - Streaming Border Overlay

/// Pulsing border overlay shown during message streaming.
/// Uses its own view identity to ensure animation state resets when streaming ends.
struct StreamingBorderOverlay: View {
    let isStreaming: Bool
    @State private var isPulsing = false

    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .stroke(
                Color.blue.opacity(isStreaming ? (isPulsing ? 0.8 : 0.3) : 0),
                lineWidth: isStreaming ? 2 : 0
            )
            .animation(
                isStreaming ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default,
                value: isPulsing
            )
            .onAppear {
                if isStreaming {
                    isPulsing = true
                }
            }
            .onChange(of: isStreaming) { _, streaming in
                isPulsing = streaming
            }
    }
}

// MARK: - Mic Button View

/// Main microphone button for voice input mode.
///
/// Accessibility: Full VoiceOver support with dynamic labels based on
/// current state (recording, speaking, processing). Announces state
/// changes and provides appropriate hints for available actions.
struct MicButtonView: View {
    let isRecording: Bool
    let isSpeaking: Bool
    let isGeneratingAudio: Bool
    let processingState: ProcessingState
    var isContinuousMode: Bool = false
    let onTap: () -> Void
    let onLongPress: () -> Void

    @State private var isLongPressing = false

    var body: some View {
        VStack(spacing: 8) {
            // Audio generation indicator (shows when Kokoro is synthesizing)
            if isGeneratingAudio {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Generating audio...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(.tertiarySystemBackground))
                .cornerRadius(12)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                .accessibilityLabel("Generating audio")
            }

            Button(action: onTap) {
                ZStack {
                    // Outer ring for active states
                    if isRecording || isSpeaking || processingState.isActive {
                        Circle()
                            .stroke(buttonColor.opacity(0.3), lineWidth: 3)
                            .frame(width: 90, height: 90)
                            .scaleEffect(isRecording ? 1.1 : 1.0)
                    }

                    Circle()
                        .fill(buttonColor)
                        .frame(width: 80, height: 80)
                        .shadow(color: buttonColor.opacity(0.3), radius: 8, x: 0, y: 4)

                    // Icon based on current state
                    buttonIcon
                        .font(.system(size: 30))
                        .foregroundColor(.white)
                }
            }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5)
                    .onEnded { _ in
                        onLongPress()
                        // Haptic feedback
                        let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
                        impactFeedback.impactOccurred()
                    }
            )
            .scaleEffect(isRecording ? 1.1 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: isRecording)
            .animation(.easeInOut(duration: 0.2), value: isSpeaking)
            .animation(.easeInOut(duration: 0.2), value: isGeneratingAudio)
            .accessibilityLabel(micButtonAccessibilityLabel)
            .accessibilityHint(micButtonAccessibilityHint)
            .accessibilityAddTraits(.isButton)

            // Hint text
            if isContinuousMode {
                Text("Continuous mode")
                    .font(.caption2)
                    .foregroundColor(.cyan)
                    .accessibilityHidden(true)
            } else if processingState.isActive {
                Text("Hold to cancel")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true) // Already conveyed in button hint
            } else if isSpeaking {
                Text("Tap to stop")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true) // Already conveyed in button hint
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Accessibility Helpers

    private var micButtonAccessibilityLabel: String {
        switch processingState {
        case .thinking:
            return "Claude is thinking"
        case .responding:
            return "Claude is responding"
        case .usingTool:
            return "Claude is using a tool"
        case .idle:
            break
        }

        if isSpeaking {
            return "Speaking response"
        }

        if isRecording {
            return "Recording"
        }

        return "Microphone"
    }

    private var micButtonAccessibilityHint: String {
        if processingState.isActive {
            return "Double tap to stop, or hold to cancel"
        }

        if isSpeaking {
            return "Double tap to stop speaking"
        }

        if isRecording {
            return "Double tap to stop recording and send"
        }

        return "Double tap to start recording"
    }

    @ViewBuilder
    private var buttonIcon: some View {
        if processingState.isActive {
            // Active streaming - show processing icon
            processingIcon
        } else if isSpeaking {
            // Speaking - show stop icon
            Image(systemName: "speaker.wave.2.fill")
        } else if isRecording {
            // Recording - show stop icon
            Image(systemName: "stop.fill")
        } else {
            // Idle - show mic icon
            Image(systemName: "mic.fill")
        }
    }

    @ViewBuilder
    private var processingIcon: some View {
        switch processingState {
        case .thinking:
            Image(systemName: "brain")
        case .responding:
            Image(systemName: "text.bubble.fill")
        case .usingTool:
            Image(systemName: "hammer.fill")
        case .idle:
            Image(systemName: "mic.fill")
        }
    }

    private var buttonColor: Color {
        // Color based on current state
        switch processingState {
        case .thinking:
            return .purple
        case .responding:
            return .blue
        case .usingTool:
            return .orange
        case .idle:
            break
        }

        if isSpeaking {
            return .green
        }

        if isRecording {
            return isContinuousMode ? .cyan : .red
        }

        return isContinuousMode ? .cyan : .blue
    }
}

// MARK: - Continuous Mode Toggle Button

/// Toggle button for continuous conversation mode.
struct ContinuousModeToggleButton: View {
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .fill(isEnabled ? Color.cyan : Color(.tertiarySystemBackground))
                    .frame(width: 44, height: 44)
                    .shadow(color: isEnabled ? Color.cyan.opacity(0.3) : Color.clear, radius: 4, x: 0, y: 2)

                Image(systemName: isEnabled ? "infinity" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(isEnabled ? .white : .secondary)
            }
        }
        .accessibilityLabel(isEnabled ? "Continuous mode enabled" : "Continuous mode disabled")
        .accessibilityHint("Double tap to toggle continuous conversation mode")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Auth Token Blocking View

struct AuthTokenBlockingView: View {
    let onOpenSettings: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.orange)

                Text("Auth Token Required")
                    .font(.headline)

                Text("Enter your gateway auth token in Settings to connect.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)

                Button("Open Settings") {
                    onOpenSettings()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .background(Color(.systemBackground))
            .cornerRadius(16)
            .padding(32)
        }
    }
}

#Preview {
    ContentView()
}
