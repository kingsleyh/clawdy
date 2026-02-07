import SwiftUI
import MarkdownUI

/// Renders assistant message text as formatted markdown.
///
/// Uses the MarkdownUI library to properly display:
/// - Code blocks with syntax highlighting and monospaced font
/// - Inline code with background highlight
/// - Bold, italic, and strikethrough text
/// - Links (tappable)
/// - Lists (ordered and unordered)
/// - Headings
/// - Block quotes
/// - Tables
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
            // Assistant messages: full markdown rendering
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
            // Code blocks
            .codeBlock { configuration in
                ScrollView(.horizontal, showsIndicators: false) {
                    configuration.label
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(.em(0.85))
                            ForegroundColor(Color(.label))
                        }
                        .padding(12)
                }
                .background(Color(.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
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

// MARK: - Preview

#Preview("Markdown Message") {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            MarkdownMessageView(
                text: """
                # Hello World

                This is a **bold** and *italic* message with `inline code`.

                ```swift
                let greeting = "Hello, World!"
                print(greeting)
                ```

                Here's a list:
                - Item one
                - Item two
                - Item three

                And a [link](https://example.com) for good measure.

                > This is a blockquote with some wisdom.

                1. First ordered item
                2. Second ordered item
                3. Third ordered item
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
