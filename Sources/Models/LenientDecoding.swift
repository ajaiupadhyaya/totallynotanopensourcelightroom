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

    /// The Optional-typed variant, for fields whose neutral value is "never
    /// set" (e.g. `PrintSettings.gradePivot`): absent, null, or unreadable
    /// decodes to `fallback` — usually `nil` — rather than dropping the whole
    /// stack. Same contract as above; a separate overload because inferring
    /// `T` as an Optional through the generic one makes the nested-optional
    /// flattening an accident of type inference instead of a documented rule.
    func lenient<T: Decodable>(_ key: Key, _ fallback: T?) -> T? {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}
