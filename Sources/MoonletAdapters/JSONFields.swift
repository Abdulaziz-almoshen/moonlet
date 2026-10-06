import Foundation

/// Read-only, typed access to a JSON object decoded by `JSONSerialization`.
struct JSONFields {
    private let storage: [String: Any]

    init(_ dictionary: [String: Any]) {
        storage = dictionary
    }

    init?(_ value: Any?) {
        guard let dictionary = value as? [String: Any] else { return nil }
        storage = dictionary
    }

    init?(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        self.init(object)
    }

    subscript(key: String) -> Any? {
        storage[key]
    }

    func string(_ key: String) -> String? {
        storage[key] as? String
    }

    /// The string at `key`, unless it's missing or only whitespace.
    func nonEmptyString(_ key: String) -> String? {
        guard let value = string(key), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    func bool(_ key: String) -> Bool? {
        storage[key] as? Bool
    }

    func object(_ key: String) -> JSONFields? {
        JSONFields(storage[key])
    }

    func array(_ key: String) -> [Any]? {
        storage[key] as? [Any]
    }
}
