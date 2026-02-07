import Foundation

/// Thinking level for the AI model.
///
/// Controls how much "thinking" (chain-of-thought reasoning) the model does
/// before responding. Higher levels produce better quality but take longer.
enum ThinkingLevel: String, Codable, CaseIterable {
    case off = "none"
    case low = "low"
    case medium = "medium"
    case high = "high"

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    var description: String {
        switch self {
        case .off: return "No thinking — fastest responses"
        case .low: return "Brief thinking — good balance"
        case .medium: return "Moderate thinking — better quality"
        case .high: return "Deep thinking — best quality, slower"
        }
    }

    var icon: String {
        switch self {
        case .off: return "bolt"
        case .low: return "brain"
        case .medium: return "brain.head.profile"
        case .high: return "sparkles"
        }
    }
}

/// Manager for thinking level setting.
/// Stored in UserDefaults.
class ThinkingLevelManager: ObservableObject {
    static let shared = ThinkingLevelManager()

    private let userDefaultsKey = "com.clawdy.thinkingLevel"

    @Published var level: ThinkingLevel {
        didSet {
            UserDefaults.standard.set(level.rawValue, forKey: userDefaultsKey)
        }
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: "com.clawdy.thinkingLevel"),
           let saved = ThinkingLevel(rawValue: raw) {
            self.level = saved
        } else {
            self.level = .low
        }
    }
}
