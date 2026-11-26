import Foundation

/// The quote page displays a rounded human size. It is a fallback for a
/// response without Content-Length, never a verified file length.
public enum ArchiveSizeEstimate {
    public static func bytes(from label: String) -> Int64? {
        let text=label.trimmingCharacters(in:.whitespacesAndNewlines)
        let number=String(text.prefix { ($0.isASCII && $0.isNumber) || $0 == "." || $0 == "," })
        let unit=text.dropFirst(number.count).trimmingCharacters(in:.whitespaces)
        let normalized=number.replacingOccurrences(of:",",with:".")
        guard normalized.range(of:#"^[0-9]+(?:\.[0-9]+)?$"#,options:.regularExpression) != nil,
              let quantity=Decimal(string:normalized,locale:Locale(identifier:"en_US_POSIX")) else { return nil }
        let multiplier:Int64
        switch unit {
        case "B": multiplier=1
        case "KB": multiplier=1_000
        case "MB": multiplier=1_000_000
        case "GB": multiplier=1_000_000_000
        case "KiB": multiplier=1_024
        case "MiB": multiplier=1_048_576
        case "GiB": multiplier=1_073_741_824
        default: return nil
        }
        let value=quantity * Decimal(multiplier)
        guard value>0,value<=Decimal(20 * 1_073_741_824) else { return nil }
        let rounded=NSDecimalNumber(decimal:value).rounding(accordingToBehavior:NSDecimalNumberHandler(
            roundingMode:.up,scale:0,raiseOnExactness:false,raiseOnOverflow:false,
            raiseOnUnderflow:false,raiseOnDivideByZero:false))
        return rounded.int64Value
    }
}
