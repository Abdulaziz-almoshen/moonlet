/// A minimal unified-style line diff, for previewing config edits.
enum LineDiff {
    /// Changed lines prefixed with `-` or `+`, with `context` unchanged lines around each
    /// change and `@@` between distant hunks. Returns `nil` when the texts are too large
    /// to compare cheaply.
    static func render(from old: String, to new: String, context: Int = 2) -> String? {
        let a = old.split(separator: "\n", omittingEmptySubsequences: false)
        let b = new.split(separator: "\n", omittingEmptySubsequences: false)
        guard a.count * b.count <= 4_000_000 else { return nil }

        // Longest common subsequence lengths, filled from the end.
        var lengths = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i][j] = a[i] == b[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }

        var lines: [(mark: Character, text: Substring)] = []
        var i = 0
        var j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                lines.append((" ", a[i]))
                i += 1
                j += 1
            } else if i < a.count, j == b.count || lengths[i + 1][j] >= lengths[i][j + 1] {
                lines.append(("-", a[i]))
                i += 1
            } else {
                lines.append(("+", b[j]))
                j += 1
            }
        }

        let changed = lines.indices.filter { lines[$0].mark != " " }
        var output: [String] = []
        var lastShown = -1
        for index in lines.indices
        where changed.contains(where: { abs($0 - index) <= context }) {
            if lastShown >= 0, index > lastShown + 1 {
                output.append("@@")
            }
            output.append("\(lines[index].mark) \(lines[index].text)")
            lastShown = index
        }
        return output.joined(separator: "\n")
    }
}
