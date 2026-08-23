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

extension String {
    /// Compares two phone numbers the way a person reads them: on digits only,
    /// and only the trailing ones, so "+91 98765 43210", "098765 43210" and
    /// "9876543210" are all the same caller. A plain `==` between a dialled
    /// number and a saved contact almost never matches.
    func matchesPhoneNumber(_ other: String) -> Bool {
        let mine = self.filter(\.isNumber)
        let theirs = other.filter(\.isNumber)
        guard mine.count >= 7, theirs.count >= 7 else { return mine == theirs }
        return mine.suffix(9) == theirs.suffix(9)
    }
}

struct AppNotification: Identifiable {
    /// The phone's own notification key — identity here, and what dismiss and
    /// reply are addressed to. Using it as `id` means an updated notification
    /// refreshes its row in place instead of replacing it.
    let key: String
    var id: String { key }
    let pkg: String
    let app: String
    let title: String
    let body: String
    let when: String
    let canReply: Bool

    /// Android app packages have no SF Symbol, so the common ones are mapped by
    /// hand and everything else falls back to a generic badge.
    var symbol: String {
        switch pkg {
        case let p where p.contains("whatsapp"): "message.fill"
        case let p where p.contains("telegram"): "paperplane.fill"
        case let p where p.contains("android.mms"), let p where p.contains("messaging"): "message.fill"
        case let p where p.contains("gm"), let p where p.contains("mail"): "envelope.fill"
        case let p where p.contains("calendar"): "calendar"
        case let p where p.contains("phone"), let p where p.contains("dialer"): "phone.fill"
        case let p where p.contains("chrome"), let p where p.contains("browser"): "safari.fill"
        case let p where p.contains("camera"), let p where p.contains("photos"): "photo.fill"
        case let p where p.contains("music"), let p where p.contains("spotify"): "music.note"
        case let p where p.contains("slack"): "number"
        case let p where p.contains("instagram"): "camera.fill"
        default: "app.badge.fill"
        }
    }

    /// Stable per-app colour, so the same app always looks the same.
    var tint: Color {
        let hash = pkg.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return Palette.avatarTints[hash % Palette.avatarTints.count]
    }
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
