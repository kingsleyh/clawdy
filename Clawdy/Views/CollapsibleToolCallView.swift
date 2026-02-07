import SwiftUI

/// A collapsible view that displays a tool call inline within a message bubble.
/// Shows tool name, input, and status in collapsed state.
/// Expands to show full output when tapped.
/// Starts expanded while running, auto-collapses after completion.
struct CollapsibleToolCallView: View {
    let toolCall: ToolCallInfo
    
    /// Whether this view is expanded (shows full output)
    @State private var isExpanded: Bool
    
    /// Animation state for the spinning indicator
    @State private var isSpinning = false
    
    init(toolCall: ToolCallInfo) {
        self.toolCall = toolCall
        // Start expanded if the tool call is still running
        _isExpanded = State(initialValue: !toolCall.isComplete)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row (always visible) - tappable to toggle expansion
            // Collapsed format: ▶ bash: ls -la ✓
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 6) {
                    // Chevron indicator (▶) for expand/collapse state
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 12)
                    
                    // Tool emoji + name with colon, followed by input: "🛠️ Bash: ls -la"
                    HStack(spacing: 0) {
                        let toolDisplay = ToolDisplayRegistry.display(for: toolCall.name)
                        Text(toolDisplay.emoji)
                            .font(.caption)
                        Text(" ")
                            .font(.caption)
                        Text(toolDisplay.name)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(toolDisplay.color)
                        
                        Text(":")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(toolDisplay.color)
                        
                        // Show input if available (truncated)
                        if let input = toolCall.input, !input.isEmpty {
                            Text(" ")
                                .font(.caption)
                            Text(truncateInput(input))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    
                    Spacer()
                    
                    // Status indicator (✓ when complete, spinner when running)
                    statusIndicator
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(backgroundColor)
                .cornerRadius(8)
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(isExpanded ? "Double tap to collapse" : "Double tap to expand")
            .accessibilityAddTraits(.isButton)
            
            // Expanded content (output details)
            if isExpanded, let output = toolCall.output, !output.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Divider()
                        .padding(.horizontal, 10)
                    
                    // Output content (truncated to ~200 words max)
                    Text(truncateOutput(output))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                }
                .background(backgroundColor)
                .cornerRadius(8, corners: [.bottomLeft, .bottomRight])
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear {
            // Start spinning indicator if tool is still running
            if !toolCall.isComplete {
                startSpinning()
            }
        }
        .onChange(of: toolCall.isComplete) { _, isComplete in
            // When tool completes: stop spinner and auto-collapse after delay
            if isComplete {
                isSpinning = false
                withAnimation(.easeInOut(duration: 0.3).delay(0.5)) {
                    isExpanded = false
                }
            }
        }
    }
    
    // MARK: - Subviews
    
    @ViewBuilder
    private var toolIcon: some View {
        switch toolCall.name.lowercased() {
        case "bash":
            Image(systemName: "terminal")
        case "read":
            Image(systemName: "doc.text")
        case "write":
            Image(systemName: "doc.badge.plus")
        case "edit":
            Image(systemName: "pencil")
        case "mcp":
            Image(systemName: "puzzlepiece")
        default:
            Image(systemName: "wrench")
        }
    }
    
    @ViewBuilder
    private var statusIndicator: some View {
        if toolCall.isComplete {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(.green)
        } else {
            // Spinning progress indicator for running tools
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 12))
                .foregroundColor(.orange)
                .rotationEffect(.degrees(isSpinning ? 360 : 0))
                .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isSpinning)
        }
    }
    
    // MARK: - Computed Properties
    
    private var formattedToolName: String {
        ToolDisplayRegistry.display(for: toolCall.name).name
    }
    
    private var iconColor: Color {
        ToolDisplayRegistry.display(for: toolCall.name).color
    }
    
    private var backgroundColor: Color {
        Color(.tertiarySystemBackground)
    }
    
    private var accessibilityLabel: String {
        var label = "Tool: \(formattedToolName)"
        if let input = toolCall.input {
            label += ", \(input)"
        }
        if toolCall.isComplete {
            label += ", completed"
        } else {
            label += ", running"
        }
        return label
    }
    
    // MARK: - Helper Methods
    
    /// Truncate input string for display in collapsed header
    private func truncateInput(_ input: String) -> String {
        // Remove newlines for single-line display
        let singleLine = input.replacingOccurrences(of: "\n", with: " ")
        
        if singleLine.count <= 30 {
            return singleLine
        }
        return String(singleLine.prefix(27)) + "..."
    }
    
    /// Truncate output to approximately 200 words with "..." suffix
    /// Preserves word boundaries and line structure where possible
    private func truncateOutput(_ output: String) -> String {
        let maxWords = 200
        
        // Split into words while preserving structure
        let words = output.split(separator: " ", omittingEmptySubsequences: false)
        
        if words.count <= maxWords {
            return output
        }
        
        // Take first ~200 words
        let truncatedWords = words.prefix(maxWords)
        var result = truncatedWords.joined(separator: " ")
        
        // Clean up trailing whitespace and add ellipsis
        result = result.trimmingCharacters(in: .whitespaces)
        
        // If we're mid-line, try to end at a natural boundary
        if let lastNewline = result.lastIndex(of: "\n"),
           result.distance(from: lastNewline, to: result.endIndex) < 50 {
            // If we're close to a newline, keep the structure
            result += "\n..."
        } else {
            result += "..."
        }
        
        return result
    }
    
    private func startSpinning() {
        isSpinning = true
    }
}

// MARK: - Corner Radius Extension

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners
    
    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

// MARK: - Preview

#Preview("Tool Call States") {
    VStack(spacing: 16) {
        // Running tool call
        CollapsibleToolCallView(
            toolCall: ToolCallInfo(
                name: "bash",
                input: "ls -la",
                output: nil,
                isComplete: false
            )
        )
        
        // Completed tool call with short output
        CollapsibleToolCallView(
            toolCall: ToolCallInfo(
                name: "read",
                input: "README.md",
                output: "# Project Title\n\nThis is a sample README file with some content for testing.",
                isComplete: true
            )
        )
        
        // Completed tool call with long output
        CollapsibleToolCallView(
            toolCall: ToolCallInfo(
                name: "bash",
                input: "cat package.json",
                output: """
                {
                  "name": "my-project",
                  "version": "1.0.0",
                  "description": "A sample project",
                  "main": "index.js",
                  "scripts": {
                    "test": "jest",
                    "build": "webpack"
                  },
                  "dependencies": {
                    "express": "^4.18.0",
                    "lodash": "^4.17.21"
                  }
                }
                """,
                isComplete: true
            )
        )
        
        // Tool call with no input
        CollapsibleToolCallView(
            toolCall: ToolCallInfo(
                name: "mcp",
                input: nil,
                output: "Tool executed successfully",
                isComplete: true
            )
        )
        
        // Write tool
        CollapsibleToolCallView(
            toolCall: ToolCallInfo(
                name: "write",
                input: "output.txt",
                output: "File written successfully",
                isComplete: true
            )
        )
        
        // Edit tool
        CollapsibleToolCallView(
            toolCall: ToolCallInfo(
                name: "edit",
                input: "config.json",
                output: "Updated 3 lines",
                isComplete: true
            )
        )
        
        // Very long output (tests ~200 word truncation)
        CollapsibleToolCallView(
            toolCall: ToolCallInfo(
                name: "bash",
                input: "cat long_file.txt",
                output: String(repeating: "Lorem ipsum dolor sit amet consectetur adipiscing elit. ", count: 50),
                isComplete: true
            )
        )
    }
    .padding()
    .background(Color(.systemBackground))
}
