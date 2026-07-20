import SwiftUI

// Data models for content synced from the phone.

struct Contact: Identifiable {
    let id = UUID()
    let name: String
    let number: String
    let tint: Color

    var initials: String {
        name.split(separator: " ").compactMap(\.first).prefix(2).map(String.init).joined()
    }
    var first: String { String(name.split(separator: " ").first ?? "") }
}

enum CallDirection {
    case incoming, outgoing, missed

    var symbol: String {
        switch self {
        case .incoming: "arrow.down.left"
        case .outgoing: "arrow.up.right"
        case .missed: "arrow.down.left"
        }
    }
}

struct RecentCall: Identifiable {
    let id = UUID()
    let name: String
    var number: String = ""
    let direction: CallDirection
    let label: String
    let when: String

    /// Two-letter initials, or empty when the caller is a bare number.
    var initials: String {
        let letters = name.split(separator: " ").compactMap(\.first).filter(\.isLetter)
        return letters.isEmpty ? "" : letters.prefix(2).map(String.init).joined().uppercased()
    }

    /// Stable avatar colour derived from the caller identity. Keyed on the name
    /// when we have one, so the same person is always the same colour.
    var tint: Color {
        let key = initials.isEmpty ? number : name
        let hash = key.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return Palette.avatarTints[hash % Palette.avatarTints.count]
    }
}

struct Message: Identifiable {
    let id = UUID()
    let me: Bool
    let text: String
    let when: String
}

struct MessageThread: Identifiable {
    let id = UUID()
    let name: String
    var preview: String
    var when: String
    var unread: Int
    let tint: Color
    var messages: [Message]

    var initials: String {
        name.split(separator: " ").compactMap(\.first).prefix(2).map(String.init).joined()
    }
}

struct AppNotification: Identifiable {
    let id = UUID()
    let app: String
    let symbol: String
    let tint: Color
    let title: String
    let body: String
    let when: String
    let canReply: Bool
}

struct ClipItem: Identifiable {
    let id = UUID()
    let symbol: String
    let body: String
    let source: String
    let when: String
}

struct FileItem: Identifiable {
    let id = UUID()
    let name: String
    let glyph: String
    let tint: Color
    let size: String
    let when: String
}
