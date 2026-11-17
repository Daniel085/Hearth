import Foundation

/// Phone numbers and emails, normalized so the same person matches across Messages,
/// call history and Contacts — which each format them differently ("+1 (415) 555-0100",
/// "4155550100", "Jane@Example.com").
public enum Handle {
    public static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("@") {
            let email = trimmed.lowercased()
            return email.count > 3 ? email : nil
        }
        let digits = trimmed.filter(\.isWholeNumber)
        // Short codes ("12345") are businesses and services, never people.
        guard digits.count >= 7 else { return nil }
        // Last ten digits: drops a leading country code like "1", so "+1 415…" and
        // "415…" match. Two different international numbers sharing their last ten
        // digits is possible but rare enough to accept for a suggestion.
        return String(digits.suffix(10))
    }
}
