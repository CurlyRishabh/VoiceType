import Foundation

/// Reading a saved list without losing all of it to one bad entry.
public enum SafeJSON {
    /// The entries of a JSON array that decode, and how many didn't. Nil when the data isn't a JSON
    /// array at all (cut short, overwritten with something else).
    public static func decodeArray<T: Decodable>(_ type: T.Type, from data: Data) -> (items: [T], dropped: Int)? {
        guard let raw = try? JSONDecoder().decode([Lenient<T>].self, from: data) else { return nil }
        let items = raw.compactMap(\.value)
        return (items, raw.count - items.count)
    }

    private struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }
}
