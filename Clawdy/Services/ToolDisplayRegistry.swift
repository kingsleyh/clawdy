import SwiftUI

/// Registry that maps tool names to user-friendly display names and emoji icons.
///
/// Inspired by the OpenClaw iOS app which uses a JSON config for this mapping.
/// This makes tool call displays much more readable than raw tool names like
/// "Read" → 📖 Read, "bash" → 🛠️ Bash, "web_search" → 🔍 Search, etc.
///
/// Usage:
/// ```swift
/// let display = ToolDisplayRegistry.display(for: "bash")
/// // display.emoji == "🛠️"
/// // display.name == "Bash"
/// // display.color == .orange
/// ```
enum ToolDisplayRegistry {

    /// Display info for a tool
    struct ToolDisplay {
        let emoji: String
        let name: String
        let color: Color
    }

    /// Known tool mappings
    private static let registry: [String: ToolDisplay] = [
        // File operations
        "read": ToolDisplay(emoji: "📖", name: "Read", color: .blue),
        "write": ToolDisplay(emoji: "📝", name: "Write", color: .green),
        "edit": ToolDisplay(emoji: "✏️", name: "Edit", color: .purple),

        // Shell / execution
        "bash": ToolDisplay(emoji: "🛠️", name: "Bash", color: .orange),
        "exec": ToolDisplay(emoji: "🛠️", name: "Exec", color: .orange),
        "process": ToolDisplay(emoji: "⚙️", name: "Process", color: .gray),

        // Web / search
        "web_search": ToolDisplay(emoji: "🔍", name: "Search", color: .blue),
        "web_fetch": ToolDisplay(emoji: "🌐", name: "Fetch", color: .cyan),
        "browser": ToolDisplay(emoji: "🌐", name: "Browser", color: .cyan),

        // Communication
        "message": ToolDisplay(emoji: "💬", name: "Message", color: .green),
        "tts": ToolDisplay(emoji: "🔊", name: "TTS", color: .indigo),

        // Memory / knowledge
        "memory_search": ToolDisplay(emoji: "🧠", name: "Memory", color: .purple),
        "memory_get": ToolDisplay(emoji: "🧠", name: "Memory", color: .purple),

        // Image / vision
        "image": ToolDisplay(emoji: "🖼️", name: "Image", color: .pink),
        "canvas": ToolDisplay(emoji: "🎨", name: "Canvas", color: .pink),

        // Node / device
        "nodes": ToolDisplay(emoji: "📱", name: "Nodes", color: .teal),
        "camera_snap": ToolDisplay(emoji: "📸", name: "Camera", color: .teal),
        "location_get": ToolDisplay(emoji: "📍", name: "Location", color: .teal),

        // Session / agent
        "sessions_spawn": ToolDisplay(emoji: "🤖", name: "Sub-Agent", color: .indigo),
        "sessions_send": ToolDisplay(emoji: "📨", name: "Send", color: .indigo),
        "sessions_list": ToolDisplay(emoji: "📋", name: "Sessions", color: .indigo),
        "session_status": ToolDisplay(emoji: "📊", name: "Status", color: .indigo),

        // System
        "cron": ToolDisplay(emoji: "⏰", name: "Cron", color: .yellow),
        "gateway": ToolDisplay(emoji: "🔧", name: "Gateway", color: .gray),

        // MCP (Model Context Protocol)
        "mcp": ToolDisplay(emoji: "🧩", name: "MCP", color: .mint),
    ]

    /// Default display for unknown tools
    private static let defaultDisplay = ToolDisplay(emoji: "🔧", name: "", color: .gray)

    /// Get display info for a tool name.
    /// Falls back to a generic wrench icon with the original name.
    static func display(for toolName: String) -> ToolDisplay {
        let key = toolName.lowercased()
        if let known = registry[key] {
            return known
        }
        // Return default with the original tool name capitalized
        return ToolDisplay(
            emoji: defaultDisplay.emoji,
            name: toolName.prefix(1).uppercased() + toolName.dropFirst(),
            color: defaultDisplay.color
        )
    }
}
