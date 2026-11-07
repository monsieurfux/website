import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0)
    }
}

/// Same palette as the Android app (dark, lime accent).
enum Theme {
    static let lime = Color(hex: 0xA6E635)
    static let muted = Color(hex: 0x9AA0A6)
    static let bgContent = Color(hex: 0x0B0E13)   // content (darkest)
    static let bgChrome = Color(hex: 0x181D25)    // navigation + tab bar
    static let bgFilter = Color(hex: 0x262E39)    // filter / bottom bars (lighter, stands out)
    static let divider = Color(hex: 0x232A33)
    static let track = Color(hex: 0x262D36)
    static let text = Color(hex: 0xE3E3E3)
    static let danger = Color(hex: 0xE5484D)
    static let warn = Color(hex: 0xF5A623)
    static let info = Color(hex: 0x7EC8FF)
    static let idle = Color(hex: 0x6B7280)
}

enum Fmt {
    private static let tsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd/MM HH:mm:ss"
        return f
    }()

    /// Recording ids are Unix timestamps (seconds).
    static func recordingTime(_ id: String) -> String {
        guard let secs = TimeInterval(id) else { return id }
        return tsFormatter.string(from: Date(timeIntervalSince1970: secs))
    }

    static func duration(_ ms: Int) -> String {
        return ms >= 1000 ? String(format: "%.1fs", Double(ms) / 1000.0) : "\(ms)ms"
    }
}
