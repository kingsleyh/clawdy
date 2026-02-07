import Foundation

/// Parses assistant response text to separate thinking from response content.
///
/// Many LLMs (Claude with extended thinking, DeepSeek, etc.) wrap their reasoning
/// in `<think>...</think>` tags. This parser extracts those segments so the UI
/// can render them differently (collapsed, italic, etc.) instead of showing raw tags.
///
/// Usage:
/// ```swift
/// let segments = AssistantTextParser.parse("Let me think...<think>reasoning here</think>The answer is 42.")
/// // segments = [.response("Let me think..."), .thinking("reasoning here"), .response("The answer is 42.")]
/// ```
enum AssistantTextParser {

    /// A segment of parsed assistant text
    enum Segment: Equatable, Identifiable {
        case thinking(String)
        case response(String)

        var id: String {
            switch self {
            case .thinking(let text): return "think_\(text.hashValue)"
            case .response(let text): return "resp_\(text.hashValue)"
            }
        }

        var text: String {
            switch self {
            case .thinking(let t): return t
            case .response(let t): return t
            }
        }

        var isThinking: Bool {
            if case .thinking = self { return true }
            return false
        }
    }

    /// Parse assistant text into segments, separating `<think>...</think>` blocks
    /// from regular response text.
    ///
    /// - Parameter text: Raw assistant response text
    /// - Returns: Array of segments in order of appearance
    static func parse(_ text: String) -> [Segment] {
        guard !text.isEmpty else { return [] }

        var segments: [Segment] = []
        var remaining = text[text.startIndex...]

        while !remaining.isEmpty {
            // Look for opening <think> tag (case-insensitive)
            if let thinkStart = remaining.range(of: "<think>", options: .caseInsensitive) {
                // Add any text before the think tag as a response segment
                let beforeThink = remaining[remaining.startIndex..<thinkStart.lowerBound]
                if !beforeThink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(.response(String(beforeThink)))
                }

                // Look for closing </think> tag
                let afterOpen = remaining[thinkStart.upperBound...]
                if let thinkEnd = afterOpen.range(of: "</think>", options: .caseInsensitive) {
                    // Extract thinking content
                    let thinkContent = afterOpen[afterOpen.startIndex..<thinkEnd.lowerBound]
                    let trimmed = thinkContent.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        segments.append(.thinking(trimmed))
                    }
                    remaining = afterOpen[thinkEnd.upperBound...]
                } else {
                    // Unclosed <think> tag — treat rest as thinking (streaming case)
                    let thinkContent = String(afterOpen).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !thinkContent.isEmpty {
                        segments.append(.thinking(thinkContent))
                    }
                    remaining = afterOpen[afterOpen.endIndex...]
                }
            } else {
                // No more think tags — rest is response text
                let text = String(remaining).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    segments.append(.response(text))
                }
                break
            }
        }

        // If no segments found (shouldn't happen with non-empty input), return as response
        if segments.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.append(.response(text))
        }

        return segments
    }

    /// Check if text contains any think tags
    static func containsThinkTags(_ text: String) -> Bool {
        text.range(of: "<think>", options: .caseInsensitive) != nil
    }

    /// Strip all think tags and their content, returning only the response text
    static func stripThinking(_ text: String) -> String {
        parse(text)
            .filter { !$0.isThinking }
            .map(\.text)
            .joined(separator: "\n\n")
    }
}
