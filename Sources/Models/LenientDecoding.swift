import Foundation

extension KeyedDecodingContainer {
    /// Decodes a value, falling back to `fallback` when the key is absent or
    /// cannot be read.
    ///
    /// Edit stacks are persisted as JSON in the catalog, so a stack written by
    /// an older build won't contain fields added since — and the synthesized
    /// decoder throws on missing keys, which would silently drop a photo's
    /// edits on upgrade. Decoding this way makes adding a field always a
    /// backward-compatible change: old rows come back with new fields at their
    /// neutral defaults.
    func lenient<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}
