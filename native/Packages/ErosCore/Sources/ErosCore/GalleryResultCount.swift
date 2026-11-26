import Foundation

/// Server-wide count for the submitted query, never the size of a loaded page.
public enum GalleryResultCount: Codable, Equatable, Sendable {
    case exact(Int), approximate(Int), atLeast(Int)
    case hundreds, thousands, tensOfThousands, hundredsOfThousands, millions, many

    public var displayText: String {
        switch self {
        case .exact(let n): return "共 \(n) 项"
        case .approximate(let n): return "约 \(n) 项"
        case .atLeast(let n): return "\(n)+ 项"
        case .hundreds: return "数百项"
        case .thousands: return "数千项"
        case .tensOfThousands: return "数万项"
        case .hundredsOfThousands: return "数十万项"
        case .millions: return "数百万项"
        case .many: return "较多（网站未给出数字）"
        }
    }

    /// Recognize the count wording returned by the website.
    public static func parse(_ text: String) -> Self? {
        let text = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // Read the count phrase even when the website appends additional text in the same block.
        let pattern = #"^found (.+?) results?(?=$|[\s.,;:(!?])"#
        // A count-only block can also contain a short form such as "about 743".
        let phrase = (try? HTMLParsing.capture(text, pattern)) ?? text
        switch phrase {
        case "hundreds of": return .hundreds
        case "thousands of": return .thousands
        case "tens of thousands of": return .tensOfThousands
        case "hundreds of thousands of": return .hundredsOfThousands
        case "millions of": return .millions
        case "many": return .many
        default: break
        }
        let qualifier = ["about ", "approximately ", "at least ", "more than ", "over "].first {
            phrase.hasPrefix($0)
        } ?? ""
        let number = String(phrase.dropFirst(qualifier.count)).trimmingCharacters(in: .whitespaces)
        let numericPattern = #"^([0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?: ?\+)?$"#
        guard let digits = try? HTMLParsing.capture(number, numericPattern),
              let count = Int(digits.replacingOccurrences(of: ",", with: "")) else { return nil }
        if number.hasSuffix("+") || ["at least ", "more than ", "over "].contains(qualifier) {
            return .atLeast(count)
        }
        return qualifier.isEmpty ? .exact(count) : .approximate(count)
    }
}
