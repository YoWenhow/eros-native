import Foundation

/// SHA-256 for translation content integrity.
public enum TranslationDigest {
    public static func sha256(_ data: Data) -> String {
        var state = StreamingSHA256()
        state.update(data)
        return state.finalized()
    }
}
