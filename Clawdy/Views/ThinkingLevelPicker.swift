import SwiftUI

/// Picker UI for selecting the AI thinking level.
///
/// Shows a segmented control with Off/Low/Medium/High options,
/// plus a description of the currently selected level.
struct ThinkingLevelPicker: View {
    @StateObject private var manager = ThinkingLevelManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Segmented picker
            Picker("Thinking", selection: $manager.level) {
                ForEach(ThinkingLevel.allCases, id: \.self) { level in
                    Label(level.displayName, systemImage: level.icon)
                        .tag(level)
                }
            }
            .pickerStyle(.segmented)

            // Description of current selection
            HStack(spacing: 6) {
                Image(systemName: manager.level.icon)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(manager.level.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Preview

#Preview("Thinking Level Picker") {
    Form {
        Section {
            ThinkingLevelPicker()
        } header: {
            Text("Thinking Level")
        }
    }
}
