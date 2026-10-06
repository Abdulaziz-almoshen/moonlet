import Foundation

/// Output helpers. Results go to stdout; notes and errors go to stderr.
enum Console {
    static func error(_ message: String) {
        FileHandle.standardError.write(Data("moonlet: \(message)\n".utf8))
    }

    static func note(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    /// Rows padded into left-aligned columns, two spaces apart.
    static func table(_ rows: [[String]]) -> String {
        let widths = rows.reduce(into: [Int]()) { widths, row in
            for (column, cell) in row.enumerated() {
                if column < widths.count {
                    widths[column] = max(widths[column], cell.count)
                } else {
                    widths.append(cell.count)
                }
            }
        }
        return rows.map { row in
            row.enumerated().map { column, cell in
                column == row.count - 1 ? cell : cell.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }
            .joined(separator: "  ")
        }
        .joined(separator: "\n")
    }

    /// "now", "42s ago", "5m ago", "3h ago", or "2d ago".
    static func age(since date: Date, now: Date = .now) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<1: return "now"
        case ..<60: return "\(seconds)s ago"
        case ..<3600: return "\(seconds / 60)m ago"
        case ..<86_400: return "\(seconds / 3600)h ago"
        default: return "\(seconds / 86_400)d ago"
        }
    }

    /// `path` with the home directory shortened to `~`.
    static func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
