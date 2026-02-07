import SwiftUI

/// Displays a collapsible thinking block from an assistant message.
///
/// When the model uses `<think>` tags, this view shows the reasoning
/// in a collapsed section that can be expanded. The thinking text
/// is rendered in italic with a distinctive visual style.
struct ThinkingBlockView: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — tappable to toggle expansion
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 12)

                    Image(systemName: "brain")
                        .font(.system(size: 12))
                        .foregroundColor(.purple)

                    Text("Thinking")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.purple)

                    Spacer()

                    // Word count hint when collapsed
                    if !isExpanded {
                        let wordCount = text.split(separator: " ").count
                        Text("\(wordCount) words")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.purple.opacity(0.08))
                .cornerRadius(8)
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("Thinking block, \(text.split(separator: " ").count) words")
            .accessibilityHint(isExpanded ? "Double tap to collapse" : "Double tap to expand")

            // Expanded content
            if isExpanded {
                Text(text)
                    .font(.callout)
                    .italic()
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.purple.opacity(0.04))
                    .cornerRadius(8, corners: [.bottomLeft, .bottomRight])
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Preview

#Preview("Thinking Block") {
    VStack(spacing: 16) {
        ThinkingBlockView(
            text: "Let me analyze this step by step. First, I need to consider the architecture of the system. The user is asking about how data flows through the pipeline, which involves several stages: ingestion, transformation, and output. Each stage has its own error handling considerations."
        )

        ThinkingBlockView(
            text: "Quick thought: the answer is 42."
        )
    }
    .padding()
}
