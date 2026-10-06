/// A command line that can't be run as given. Exits with status 2.
struct UsageError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

/// Takes options and positional arguments off a command line, then insists nothing is left.
struct Arguments {
    private var arguments: [String]

    init(_ arguments: [String]) {
        self.arguments = arguments
    }

    /// Removes `name` and reports whether it was present.
    mutating func flag(_ name: String) -> Bool {
        guard let index = arguments.firstIndex(of: name) else { return false }
        arguments.remove(at: index)
        return true
    }

    /// Removes `name value` or `name=value` and returns the value.
    mutating func option(_ name: String) throws -> String? {
        if let index = arguments.firstIndex(of: name) {
            guard index + 1 < arguments.count else { throw UsageError("\(name) needs a value.") }
            let value = arguments[index + 1]
            arguments.removeSubrange(index...(index + 1))
            return value
        }
        if let index = arguments.firstIndex(where: { $0.hasPrefix(name + "=") }) {
            return String(arguments.remove(at: index).dropFirst(name.count + 1))
        }
        return nil
    }

    /// Removes and returns the first argument that isn't an option.
    mutating func positional(_ what: String) throws -> String {
        guard let index = arguments.firstIndex(where: { !$0.hasPrefix("-") }) else {
            throw UsageError("Expected \(what).")
        }
        return arguments.remove(at: index)
    }

    /// Throws if any argument went unused.
    func finish() throws {
        if let unused = arguments.first {
            throw UsageError(unused.hasPrefix("-") ? "Unknown option \(unused)." : "Unexpected argument \(unused).")
        }
    }
}
