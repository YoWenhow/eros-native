import Foundation
import SwiftSoup

public enum AccountOverviewEndpoint {
    public static let quota = URL(string: "https://e-hentai.org/home.php")!
    public static let gp = URL(string: "https://e-hentai.org/exchange.php?t=gp")!
    public static let hath = URL(string: "https://e-hentai.org/exchange.php?t=hath")!
    public static let resetBody = Data("reset_imagelimit=Reset+Quota".utf8)
}

public struct ImageQuota: Equatable, Sendable {
    public let used: Int
    public let limit: Int
    public let resetCostGP: Int?
}

public struct AccountAssets: Equatable, Sendable {
    public let credits: Int
    public let kiloGP: Int
    public let hath: Decimal
}

public struct AccountOverviewParser: Sendable {
    public init() {}

    public func quota(_ response: HTTPResponse) throws -> ImageQuota {
        let endpoint = AccountOverviewEndpoint.quota
        guard response.finalURL == endpoint, response.scope.storage.site == .eh,
              response.body.count <= 2_000_000 else { throw AppError.parseMismatch }
        let context = RequestContext(scope: response.scope, queryID: response.requestID)
        let document = try HTMLParsing.document(response, context: context, policy: ParsingPolicy())
        let headings = try document.select(".stuffbox > h2").filter { (try? $0.text()) == "Image Limits" }
        guard headings.count == 1, let card = try headings.first?.nextElementSibling(), card.hasClass("homebox")
        else { throw AppError.parseMismatch }
        let paragraphs = try card.select("p").array().map { try $0.text() }
        let usagePattern = #"(?i)^You are currently at\s+([\d,]+)\s+towards your account limit of\s+([\d,]+)\s*\.?$"#
        let counters = try paragraphs.compactMap { text -> (Int, Int)? in
            guard let used = try integer(HTMLParsing.capture(text, usagePattern, group: 1)),
                  let limit = try integer(HTMLParsing.capture(text, usagePattern, group: 2)) else { return nil }
            return (used, limit)
        }
        guard counters.count == 1, let (used, limit) = counters.first else { throw AppError.parseMismatch }
        let resetCost = used > 0 && limit > 0 ? try resetCost(card: card, paragraphs: paragraphs, endpoint: endpoint) : nil
        return ImageQuota(used: used, limit: limit, resetCostGP: resetCost)
    }

    private func resetCost(card: Element, paragraphs: [String], endpoint: URL) throws -> Int? {
        let reset = try card.select("form input[name=reset_imagelimit]")
        guard reset.size() == 1, let submit = reset.first(), let form = submit.parents().array().first(where: { $0.tagName() == "form" }),
              try form.attr("method").lowercased() == "post", try submit.attr("type").lowercased() == "submit",
              try submit.attr("value") == "Reset Quota",
              try form.attr("action").isEmpty || URL(string: form.attr("action"), relativeTo: endpoint)?.absoluteURL == endpoint,
              try form.attr("enctype").isEmpty || form.attr("enctype").lowercased() == "application/x-www-form-urlencoded",
              !submit.hasAttr("disabled"), !submit.hasAttr("formaction"), !submit.hasAttr("formmethod"),
              !submit.parents().array().contains(where: { $0.tagName() == "fieldset" && $0.hasAttr("disabled") }),
              try form.select("input, select, textarea, button").size() == 1,
              let cost = paragraphs.first(where: { $0.hasPrefix("You can reset your image quota ") })
        else { return nil }
        return try integer(HTMLParsing.capture(cost, #"^You can reset your image quota by spending ([\d,]+) GP\.$"#))
    }

    public func assets(gp: HTTPResponse, hath: HTTPResponse) throws -> AccountAssets {
        guard gp.scope == hath.scope else { throw AppError.staleSession }
        let gpValue = try exchange(gp, at: AccountOverviewEndpoint.gp, unit: "kGP")
        let hathValue = try exchange(hath, at: AccountOverviewEndpoint.hath, unit: "Hath")
        guard let kiloGP = integer(gpValue.available),
              let hathBalance = Decimal(string: hathValue.available.replacingOccurrences(of: ",", with: ""),
                  locale: Locale(identifier: "en_US_POSIX")), !hathBalance.isNaN, hathBalance >= 0 else {
            throw AppError.parseMismatch
        }
        return AccountAssets(credits: gpValue.credits, kiloGP: kiloGP, hath: hathBalance)
    }

    private func exchange(_ response: HTTPResponse, at endpoint: URL, unit: String) throws -> (credits: Int, available: String) {
        guard response.finalURL == endpoint, response.scope.storage.site == .eh,
              response.body.count <= 2_000_000 else { throw AppError.parseMismatch }
        let context = RequestContext(scope: response.scope, queryID: response.requestID)
        let document = try HTMLParsing.document(response, context: context, policy: ParsingPolicy())
        guard let buy = try document.select("form#buyform").first()?.parent()?.nextElementSibling(),
              let sell = try document.select("form#sellform").first()?.parent()?.nextElementSibling(),
              let credits = try integer(HTMLParsing.capture(buy.text(), #"^Available:\s*([\d,]+)\s+Credits$"#)),
              let available = try HTMLParsing.capture(sell.text(), #"^Available:\s*([\d,]+(?:\.\d+)?)\s+"# + unit + "$")
        else { throw AppError.parseMismatch }
        return (credits, available)
    }

    private func integer(_ raw: String?) -> Int? {
        guard let raw, raw.range(of: #"^(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)$"#, options: .regularExpression) != nil
        else { return nil }
        return Int(raw.replacingOccurrences(of: ",", with: ""))
    }
}
