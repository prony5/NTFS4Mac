import Foundation

enum AppInfo {
    static var version: String {
        if let plist = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !plist.isEmpty {
            return plist
        }
        if let url = Bundle.main.url(forResource: "VERSION", withExtension: nil),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return "0.0.0"
    }
}
