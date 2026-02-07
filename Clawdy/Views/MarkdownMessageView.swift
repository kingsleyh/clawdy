import SwiftUI
import MarkdownUI
import HighlightSwift

/// Renders assistant message text as formatted markdown with syntax-highlighted code blocks.
///
/// Uses the MarkdownUI library for markdown rendering and HighlightSwift for
/// syntax highlighting in code blocks. Supports 50+ languages with automatic
/// language detection.
///
/// Falls back to plain Text() for user messages (which are typically short and don't need markdown).
struct MarkdownMessageView: View {
    let text: String
    let isUser: Bool

    var body: some View {
        if isUser {
            // User messages: plain text, no markdown rendering needed
            Text(text)
                .foregroundColor(.white)
                .textSelection(.enabled)
        } else {
            // Assistant messages: full markdown rendering with syntax highlighting
            Markdown(text)
                .markdownTheme(clawdyTheme)
                .textSelection(.enabled)
        }
    }

    /// Custom markdown theme matching Clawdy's design
    private var clawdyTheme: Theme {
        Theme()
            // Body text
            .text {
                ForegroundColor(.primary)
                FontSize(.em(1.0))
            }
            // Code blocks — use HighlightSwift for syntax highlighting
            .codeBlock { configuration in
                SyntaxHighlightedCodeBlock(
                    code: configuration.content,
                    language: configuration.language
                )
                .markdownMargin(top: 8, bottom: 8)
            }
            // Inline code
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.85))
                ForegroundColor(Color(.systemOrange))
                BackgroundColor(Color(.tertiarySystemBackground))
            }
            // Strong (bold)
            .strong {
                FontWeight(.semibold)
            }
            // Emphasis (italic)
            .emphasis {
                FontStyle(.italic)
            }
            // Links
            .link {
                ForegroundColor(.blue)
            }
            // Headings
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.bold)
                        FontSize(.em(1.4))
                    }
                    .markdownMargin(top: 16, bottom: 8)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.bold)
                        FontSize(.em(1.2))
                    }
                    .markdownMargin(top: 12, bottom: 6)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.1))
                    }
                    .markdownMargin(top: 10, bottom: 4)
            }
            // Block quotes
            .blockquote { configuration in
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 4)
                    configuration.label
                        .markdownTextStyle {
                            ForegroundColor(.secondary)
                            FontStyle(.italic)
                        }
                        .padding(.leading, 12)
                }
                .markdownMargin(top: 8, bottom: 8)
            }
            // List items
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: 2, bottom: 2)
            }
            // Thematic break (horizontal rule)
            .thematicBreak {
                Divider()
                    .markdownMargin(top: 12, bottom: 12)
            }
            // Table styling
            .table { configuration in
                configuration.label
                    .markdownTableBorderStyle(.init(color: .secondary.opacity(0.3)))
                    .markdownMargin(top: 8, bottom: 8)
            }
            .tableCell { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(.em(0.9))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
    }
}

// MARK: - Syntax Highlighted Code Block

/// A code block view with syntax highlighting powered by HighlightSwift.
///
/// Features:
/// - Automatic language detection (50+ languages)
/// - Manual language hint from markdown fence (```swift, ```python, etc.)
/// - Dark/light mode support via GitHub theme
/// - Horizontal scrolling for wide code
/// - Language label badge
/// - Copy button
struct SyntaxHighlightedCodeBlock: View {
    let code: String
    let language: String?

    @Environment(\.colorScheme) private var colorScheme
    @State private var highlightedText: AttributedString?
    @State private var highlightedCode: String?
    @State private var detectedLanguage: String?
    @State private var copied = false

    /// Whether the highlighted text is current (matches the code being displayed)
    private var isHighlightCurrent: Bool {
        highlightedText != nil && highlightedCode == code
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar with language label and copy button
            HStack {
                if let lang = language ?? detectedLanguage {
                    Text(lang)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                }
                Spacer()
                Button(action: copyCode) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                        Text(copied ? "Copied" : "Copy")
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // Code content — always show plain text, overlay highlighted version when ready
            ScrollView(.horizontal, showsIndicators: false) {
                if isHighlightCurrent, let highlighted = highlightedText {
                    Text(highlighted)
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                        .transition(.opacity)
                } else {
                    Text(code)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                        .transition(.opacity)
                }
            }
            .animation(.easeIn(duration: 0.3), value: isHighlightCurrent)
        }
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: code) {
            // Debounce: wait for streaming to settle before highlighting
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await highlight()
        }
        .onChange(of: colorScheme) { _, _ in
            Task { await highlight() }
        }
    }

    /// Perform syntax highlighting asynchronously
    private func highlight() async {
        let codeSnapshot = code
        let highlight = Highlight()
        let colors: HighlightColors = colorScheme == .dark ? .dark(.github) : .light(.github)
        do {
            let result: HighlightResult
            if let language = language, !language.isEmpty {
                // Use specified language
                result = try await highlight.request(codeSnapshot, mode: .languageAlias(language), colors: colors)
            } else {
                // Auto-detect language
                result = try await highlight.request(codeSnapshot, colors: colors)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.highlightedText = result.attributedText
                self.highlightedCode = codeSnapshot
                self.detectedLanguage = result.language
            }
        } catch {
            print("[MarkdownMessageView] Syntax highlighting error: \(error)")
        }
    }

    /// Copy code to clipboard
    private func copyCode() {
        UIPasteboard.general.string = code
        withAnimation {
            copied = true
        }
        // Reset after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                copied = false
            }
        }
    }
}

// MARK: - Preview

#Preview("Markdown Message") {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            MarkdownMessageView(
                text: """
                # Hello World

                This is a **bold** and *italic* message with `inline code`.

                ```swift
                struct ContentView: View {
                    @State private var count = 0

                    var body: some View {
                        VStack {
                            Text("Count: \\(count)")
                                .font(.title)
                            Button("Increment") {
                                count += 1
                            }
                        }
                    }
                }
                ```

                And some Python:

                ```python
                def fibonacci(n):
                    if n <= 1:
                        return n
                    return fibonacci(n-1) + fibonacci(n-2)

                print(fibonacci(10))
                ```

                Here's a list:
                - Item one
                - Item two
                - Item three

                > This is a blockquote with some wisdom.
                """,
                isUser: false
            )
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(16)

            MarkdownMessageView(
                text: "How do I fix this error?",
                isUser: true
            )
            .padding()
            .background(Color.blue)
            .cornerRadius(16)
        }
        .padding()
    }
}
