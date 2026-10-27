//
//  RequesterOrderDeterministicEvidence.swift
//  CommonPlateios
//
// W4-S3 Requester adapter: the on-device port of the accepted deterministic
// Requester Screenshot Assistance rules in `src/screenshotEligibility.ts` and
// `src/screenshotProposalValidation.ts`. Local analysis may not depend on an
// off-device validation call, so eligibility, meal-swipe corroboration,
// vendor grounding, and the current-cart Dining Dollars rule are evaluated
// here, against on-device Vision OCR text only — never against anything a
// provider (local or external) returned. Everything in this file is Requester
// policy (Grubhub cart/history categories, catalog vendors, meal swipes,
// Dining Dollars); the shared runtime knows none of it.
//
// This is a port, not a redesign: the backend rules stay authoritative for the
// external route and `shared/screenshot-conformance-vectors.json` is asserted
// by both suites (`src/screenshotConformanceVectors.test.ts`,
// `ScreenshotConformanceVectorTests.swift`) so neither side can drift silently.
// The helpers below deliberately reproduce JavaScript's text semantics
// (`\s`, `\w`, `\b`, `trim`, case-insensitive matching restricted to ASCII)
// rather than Swift's or ICU's defaults, because a divergence in how a
// boundary or whitespace character is treated would be a divergence in a
// fail-closed rule.
import Foundation

/// JavaScript text semantics the accepted rules were written against.
enum ScreenshotJSText {
    /// The exact code points ECMAScript's `\s` and `String.prototype.trim`
    /// treat as white space or line terminators.
    static let whitespaceScalars: Set<Unicode.Scalar> = {
        var scalars: Set<Unicode.Scalar> = [
            "\u{0009}", "\u{000A}", "\u{000B}", "\u{000C}", "\u{000D}", "\u{0020}",
            "\u{00A0}", "\u{1680}", "\u{2028}", "\u{2029}", "\u{202F}", "\u{205F}",
            "\u{3000}", "\u{FEFF}",
        ]
        for value in 0x2000...0x200A {
            scalars.insert(Unicode.Scalar(UInt32(value))!)
        }
        return scalars
    }()

    /// A regular-expression character-class body matching exactly
    /// `whitespaceScalars` (ICU's own `\s` differs, e.g. it includes U+0085).
    static let whitespaceClassBody =
        "\\t\\n\\x{0B}\\f\\r \\x{A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}"

    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        whitespaceScalars.contains(scalar)
    }

    /// `text.replace(/\s+/g, "").length` — a UTF-16 code-unit count.
    static func nonWhitespaceLength(_ text: String) -> Int {
        var count = 0
        for scalar in text.unicodeScalars where !isWhitespace(scalar) {
            count += scalar.value > 0xFFFF ? 2 : 1
        }
        return count
    }

    /// `text.replace(/\s+/g, " ").trim()`.
    static func collapsingWhitespace(_ text: String) -> String {
        var pieces: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if isWhitespace(scalar) {
                if !current.isEmpty {
                    pieces.append(String(current))
                    current = String.UnicodeScalarView()
                }
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { pieces.append(String(current)) }
        return pieces.joined(separator: " ")
    }

    /// `text.trim()`.
    static func trimmed(_ text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        while let last = scalars.last, isWhitespace(last) { scalars.removeLast() }
        var start = 0
        while start < scalars.count, isWhitespace(scalars[start]) { start += 1 }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[start...])
        return String(view)
    }

    /// `text.toLowerCase().replace(/\s+/g, " ").trim()`.
    static func normalized(_ text: String) -> String {
        collapsingWhitespace(text.lowercased())
    }

    /// Lowercases only `A`–`Z`. A JavaScript `i`-flag pattern made of ASCII
    /// letters never matches a non-ASCII character (`ſ`, the Kelvin sign), but
    /// ICU's case-insensitive matching does — so case-insensitive rules here
    /// fold ASCII only and then match a lowercase pattern.
    static func asciiLowercased(_ text: String) -> String {
        var view = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x41 && scalar.value <= 0x5A {
                view.append(Unicode.Scalar(scalar.value + 0x20)!)
            } else {
                view.append(scalar)
            }
        }
        return String(view)
    }

    /// Exact UTF-16 code-unit substring test. Swift's `String.contains` and
    /// `==` apply canonical equivalence, JavaScript's `includes`/`===` do not.
    static func literalContains(_ haystack: String, _ needle: String) -> Bool {
        (haystack as NSString).range(of: needle, options: .literal).location != NSNotFound
    }

    static func literalEquals(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16)
    }

    static func makeRegex(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: [])
        } catch {
            preconditionFailure("Invalid screenshot rule pattern \(pattern): \(error)")
        }
    }

    static func hasMatch(_ regex: NSRegularExpression, in text: String) -> Bool {
        regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    static func matches(_ regex: NSRegularExpression, in text: String) -> [[String?]] {
        let nsText = text as NSString
        return regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length)).map { match in
            (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : nsText.substring(with: range)
            }
        }
    }
}

struct RequesterOrderEligibilityResult: Equatable {
    enum Category: String, Equatable {
        case cart
        case historical
        /// W4-R4.1 Grubhub checkout/review (`isCheckoutReview`).
        case checkout
    }

    let eligible: Bool
    let category: Category?
}

enum RequesterOrderDeterministicEvidence {
    private static let legibilityMinimumNonWhitespaceCharacters = 20

    // ASCII-only stand-ins for JavaScript's `\w`/`\b`/`\d` (see
    // `ScreenshotJSText`).
    private static let wordClass = "A-Za-z0-9_"
    private static let ws = "[\(ScreenshotJSText.whitespaceClassBody)]"

    /// `/(^|\s)(\d{1,2})\s?x?\s+[a-z][a-z'&()-]{2,}(\s+[a-z][a-z'&()-]+){0,6}/`
    /// evaluated on text whose white space is already collapsed to single
    /// spaces, so `\s` is a literal space here.
    private static let quantifiedItem = ScreenshotJSText.makeRegex(
        "(^| )([0-9]{1,2}) ?x? +[a-z][a-z'\\&()\\-]{2,}( +[a-z][a-z'\\&()\\-]+){0,6}"
    )
    /// `/\bview order\b(?! details)/`
    private static let viewOrder = ScreenshotJSText.makeRegex(
        "(?<![\(wordClass)])view order(?![\(wordClass)])(?! details)"
    )
    /// `/\border information\b/`
    private static let orderInformation = ScreenshotJSText.makeRegex(
        "(?<![\(wordClass)])order information(?![\(wordClass)])"
    )
    /// `/(?<![\w.])(\d{1,2})\s?M\b/g`
    private static let explicitMealSwipeTotal = ScreenshotJSText.makeRegex(
        "(?<![\(wordClass).])([0-9]{1,2})\(ws)?M(?![\(wordClass)])"
    )
    /// `/\b(?:your\s+(?:pickup\s+)?order|cart|checkout|continue\s+to\s+checkout)\b/i`
    /// on ASCII-lowercased text.
    private static let currentCartMarkers = ScreenshotJSText.makeRegex(
        "(?<![a-z0-9_])(?:your\(ws)+(?:pickup\(ws)+)?order|cart|checkout|continue\(ws)+to\(ws)+checkout)(?![a-z0-9_])"
    )
    /// `/\b(?:past\s+order|order\s+history|receipt|delivered|completed)\b/i`
    /// on ASCII-lowercased text.
    private static let pastOrderMarkers = ScreenshotJSText.makeRegex(
        "(?<![a-z0-9_])(?:past\(ws)+order|order\(ws)+history|receipt|delivered|completed)(?![a-z0-9_])"
    )
    /// `/(?<![\w.])(\d{1,2})\s?M\s*\+\s*\$(\d{1,2})(?:\.(\d{2}))?(?!\d)/g`
    private static let cartDollar = ScreenshotJSText.makeRegex(
        "(?<![\(wordClass).])([0-9]{1,2})\(ws)?M\(ws)*\\+\(ws)*\\$([0-9]{1,2})(?:\\.([0-9]{2}))?(?![0-9])"
    )

    /// `/^(\d{1,2})\s?x?\s+[a-z][a-z'&()-]{2,}(\s+[a-z][a-z'&()-]+){0,6}/` on one
    /// normalized line (the W4-R4.1 `Your order` item line).
    private static let lineQuantifiedItem = ScreenshotJSText.makeRegex(
        "^([0-9]{1,2}) ?x? +[a-z][a-z'\\&()\\-]{2,}( +[a-z][a-z'\\&()\\-]+){0,6}"
    )
    /// A full normalized venue/menu identity line ending in ` - meal exchange`.
    private static let explicitMealExchange = ScreenshotJSText.makeRegex(
        "^(?:meal exchange|.+ - meal exchange)$"
    )
    private static let mealPayment = ScreenshotJSText.makeRegex(
        "^(?:payment method:? )?use [1-5] meals? \\+ dining dollars$"
    )
    private static let totalWithAmount = ScreenshotJSText.makeRegex(
        "^total +\\$([0-9]{1,4})(?:\\.([0-9]{2}))?$"
    )
    private static let amountOnly = ScreenshotJSText.makeRegex(
        "^\\$([0-9]{1,4})(?:\\.([0-9]{2}))?$"
    )
    private static let splitTender = ScreenshotJSText.makeRegex(
        "(?<![a-z])(?:split payment|split tender|multiple payment methods)(?![a-z])"
    )
    private static let otherTender = ScreenshotJSText.makeRegex(
        "^(?:visa|mastercard|amex|american express|credit card|debit card|apple pay)(?![a-z])"
    )
    private static let mixedTender = ScreenshotJSText.makeRegex(
        "^(?:dining dollars|use [1-5] meals? \\+ dining dollars) (?:and|\\+) (?:visa|mastercard|amex|american express|credit card|debit card|apple pay)(?![a-z])"
    )
    private static let diningTenderAmount = ScreenshotJSText.makeRegex(
        "^dining dollars +\\$[0-9]"
    )
    private static let otherTenderAmount = ScreenshotJSText.makeRegex(
        "^(?:visa|mastercard|amex|american express|credit card|debit card|apple pay)(?![a-z]).*\\$[0-9]"
    )

    private static func hasMealExchangeIdentity(_ lines: [String]) -> Bool {
        lines.indices.contains { index in
            let line = lines[index]
            if ScreenshotJSText.hasMatch(explicitMealExchange, in: line) { return true }
            guard index + 1 < lines.count,
                  ScreenshotJSText.literalEquals(lines[index + 1], "exchange") else { return false }
            return ScreenshotJSText.literalEquals(line, "meal")
                || line.hasSuffix(" - meal")
        }
    }

    // MARK: - Checkout/review category (W4-R4.1)

    private static let checkoutReviewHeadings: Set<String> = [
        "review your pickup order",
        "review your delivery order",
    ]
    private static let yourOrderSection = "your order"
    private static let yourPaymentSection = "your payment"
    private static let paymentMethodLabel = "payment method"
    /// Other recognized top-level structures. Reaching one ends `Your payment`
    /// attribution; none of them opens payment authority.
    private static let receiptSection = "receipt"
    private static let orderConfirmationSection = "order confirmation"
    private static let orderInformationSection = "order information"
    private static let viewOrderTitle = "view order"
    private static let diningDollarsValue = "dining dollars"
    private static let genericReviewBoundary = "review your order"

    /// Normalized, non-empty lines. Only CR, LF, and CRLF split lines — the
    /// exact rule `src/screenshotEligibility.ts` uses — so row/section
    /// attribution cannot drift between implementations.
    static func normalizedLines(_ text: String) -> [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        var previousWasCR = false
        func flush() {
            lines.append(ScreenshotJSText.normalized(String(current)))
            current = String.UnicodeScalarView()
        }
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                if previousWasCR { previousWasCR = false; continue }
                flush()
            } else if scalar == "\r" {
                flush()
                previousWasCR = true
                continue
            } else {
                current.append(scalar)
            }
            previousWasCR = false
        }
        flush()
        return lines.filter { !$0.isEmpty }
    }

    /// The text after a `Payment method` label on the same line (`""` for the
    /// bare label), or `nil` when the line is not a Payment method row. A
    /// label glued to other letters is not a row.
    private static func paymentMethodRowRemainder(_ line: String) -> String? {
        if ScreenshotJSText.literalEquals(line, paymentMethodLabel) { return "" }
        guard line.utf16.starts(with: paymentMethodLabel.utf16) else { return nil }
        let units = Array(line.utf16.dropFirst(paymentMethodLabel.utf16.count))
        guard let first = units.first else { return "" }
        let space: UInt16 = 0x20
        let colon: UInt16 = 0x3A
        if first == space {
            return ScreenshotJSText.trimmed(String(decoding: units, as: UTF16.self))
        }
        if first == colon {
            return ScreenshotJSText.trimmed(String(decoding: units.dropFirst(), as: UTF16.self))
        }
        return nil
    }

    /// Rejoin only exact canonical labels split across adjacent Vision lines.
    private static func labelSpan(_ lines: [String], _ index: Int, _ label: String, maxLines: Int) -> Int {
        guard index < lines.count else { return 0 }
        for count in 1...min(maxLines, lines.count - index) {
            if ScreenshotJSText.literalEquals(lines[index..<(index + count)].joined(separator: " "), label) {
                return count
            }
        }
        return 0
    }

    private static func headingSpan(_ lines: [String], _ index: Int) -> Int {
        for heading in checkoutReviewHeadings {
            let span = labelSpan(lines, index, heading, maxLines: 3)
            if span > 0 { return span }
        }
        return 0
    }

    private struct PaymentRow {
        let index: Int
        let span: Int
        let remainder: String
    }

    private static func paymentRow(_ lines: [String], _ index: Int) -> PaymentRow? {
        if let remainder = paymentMethodRowRemainder(lines[index]) {
            return PaymentRow(index: index, span: 1, remainder: remainder)
        }
        guard ScreenshotJSText.literalEquals(lines[index], "payment"), index + 1 < lines.count else { return nil }
        let second = lines[index + 1]
        if ScreenshotJSText.literalEquals(second, "method") {
            return PaymentRow(index: index, span: 2, remainder: "")
        }
        let units = Array(second.utf16)
        guard units.starts(with: Array("method".utf16)), units.count > 6,
              units[6] == 0x20 || units[6] == 0x3A else { return nil }
        let suffix = units[6] == 0x3A ? units.dropFirst(7) : units.dropFirst(6)
        return PaymentRow(index: index, span: 2,
                          remainder: ScreenshotJSText.trimmed(String(decoding: suffix, as: UTF16.self)))
    }

    private static func paymentRows(_ lines: [String]) -> [PaymentRow] {
        var rows: [PaymentRow] = []
        var index = 0
        while index < lines.count {
            if let row = paymentRow(lines, index) {
                rows.append(row)
                index += row.span
            } else {
                index += 1
            }
        }
        return rows
    }

    // MARK: Structural departures (boundary recognition only)
    //
    // A departure is a line that shows the screenshot has left the section being
    // attributed (`Your payment` or `Your order`). Recognition is deliberately
    // separate from positive evidence: a departure ends attribution and never
    // establishes review eligibility, a menu path, or a screenshot category.
    //
    // Each departure is an already-known structural label, either exact (whole
    // on one line or split across adjacent lines, like every other label) or with
    // one narrow decoration on its own line: a trailing affordance, a `:`/`#`
    // order-reference token, or a trailing price (CTA button). The label must be
    // followed by a delimiter, so `receipts` or `receipt of` are not departures.
    // No fuzzy matching and no line-distance cutoff. Mirrors
    // `departureAt` in `src/screenshotEligibility.ts`.

    private enum Departure {
        case yourOrder, yourPayment, receipt, confirmation, information
        case history, viewOrder, heading, placeOrder
    }

    private static let departureLabels: [(Departure, [String], Int)] = [
        (.yourOrder, [yourOrderSection], 2),
        (.yourPayment, [yourPaymentSection], 2),
        (.receipt, [receiptSection], 2),
        (.confirmation, [orderConfirmationSection], 2),
        (.information, [orderInformationSection], 2),
        (.history, ["order history", "past order", "past orders"], 2),
        (.viewOrder, [viewOrderTitle], 2),
        (.heading, Array(checkoutReviewHeadings), 3),
        (.placeOrder, ["place your order", "place your pickup order", "place your delivery order"], 3),
    ]

    /// What may follow a departure label on its line (normalized lines hold a
    /// single ASCII space as their only whitespace).
    private static let departureDecoration = ScreenshotJSText.makeRegex(
        "^(?: ?[>\\u203A\\u00BB\\u276F\\u2192\\u2022\\u00B7|\\u2013\\u2014-]"
            + "| ?[:#] ?[a-z0-9][a-z0-9-]{0,31}| ?\\$[0-9][0-9.,]*)*$"
    )

    private static func decoratedLabel(_ line: String, _ label: String) -> Bool {
        guard line.utf16.count > label.utf16.count, line.utf16.starts(with: label.utf16) else { return false }
        let remainder = String(decoding: Array(line.utf16.dropFirst(label.utf16.count)), as: UTF16.self)
        return ScreenshotJSText.hasMatch(departureDecoration, in: remainder)
    }

    private static func departureAt(_ lines: [String], _ index: Int) -> Departure? {
        if ScreenshotJSText.literalEquals(lines[index], genericReviewBoundary) { return .heading }
        for (kind, labels, maxLines) in departureLabels {
            for label in labels
            where labelSpan(lines, index, label, maxLines: maxLines) > 0 || decoratedLabel(lines[index], label) {
                return kind
            }
        }
        return nil
    }

    /// First departure at or after `from`, optionally ignoring `Your order` (a
    /// second `Your order` heading does not leave the order section).
    private static func firstDeparture(_ lines: [String], from: Int, ignoreYourOrder: Bool) -> Int {
        var index = from
        while index < lines.count {
            if let kind = departureAt(lines, index), !(ignoreYourOrder && kind == .yourOrder) { return index }
            index += 1
        }
        return lines.count
    }

    /// The one bounded `Your payment` section, or `nil` when the heading is
    /// absent or duplicated, including a decorated duplicate (ambiguous payment
    /// structure fails closed). Only the exact label opens the section.
    private static func paymentSection(_ lines: [String]) -> Range<Int>? {
        let starts = lines.indices.filter { labelSpan(lines, $0, yourPaymentSection, maxLines: 2) > 0 }
        guard starts.count == 1, let start = starts.first else { return nil }
        let span = labelSpan(lines, start, yourPaymentSection, maxLines: 2)
        for index in lines.indices where (index < start || index >= start + span)
            && departureAt(lines, index) == .yourPayment {
            return nil
        }
        let contentStart = start + span
        return contentStart..<firstDeparture(lines, from: contentStart, ignoreYourOrder: false)
    }

    private static func isCheckoutReview(_ lines: [String]) -> Bool {
        let headings = lines.indices.filter { headingSpan(lines, $0) > 0 }
        guard headings.count == 1, let headingIndex = headings.first else { return false }
        let payment = paymentSection(lines)
        let orderIndex = lines.indices.first { labelSpan(lines, $0, yourOrderSection, maxLines: 2) > 0 }
        if let orderIndex {
            // `Your order` ends at the first structural departure after it
            // (first later `Your payment`, receipt/confirmation/history, ...),
            // whether or not the payment section there is valid, duplicated,
            // or malformed.
            let contentStart = orderIndex + labelSpan(lines, orderIndex, yourOrderSection, maxLines: 2)
            let end = firstDeparture(lines, from: contentStart, ignoreYourOrder: true)
            for index in contentStart..<max(end, contentStart)
            where ScreenshotJSText.hasMatch(lineQuantifiedItem, in: lines[index]) {
                return true
            }
        }
        guard let payment, payment.lowerBound > headingIndex else { return false }
        let rows = paymentRows(lines)
        return rows.count == 1 && payment.contains(rows[0].index)
    }

    /// Cart/bag chrome phrases (C1). Checkout-context phrasing is excluded
    /// even though it contains the cart phrase as a substring.
    private static let cartChromePhrases = [
        "your pickup order",
        "your delivery order",
        "order instructions",
        "cilantro on the side",
        "continue to checkout",
        "add more items",
        "empty bag",
        "items subtotal",
    ]

    private static func cartChromeCount(_ normalized: String) -> Int {
        var count = 0
        for phrase in cartChromePhrases {
            guard ScreenshotJSText.literalContains(normalized, phrase) else { continue }
            if phrase == "your pickup order",
               ScreenshotJSText.literalContains(normalized, "review your pickup order")
                || ScreenshotJSText.literalContains(normalized, "place your pickup order") {
                continue
            }
            if phrase == "your delivery order",
               ScreenshotJSText.literalContains(normalized, "review your delivery order")
                || ScreenshotJSText.literalContains(normalized, "place your delivery order") {
                continue
            }
            count += 1
        }
        return count
    }

    /// The accepted V1-C1-or-H5 rule, evaluated against literal on-device
    /// evidence text only. Eligibility is accident prevention, not
    /// authenticity verification (`docs/system-contract.md` section 12).
    static func evaluateEligibility(_ evidenceText: String) -> RequesterOrderEligibilityResult {
        guard ScreenshotJSText.nonWhitespaceLength(evidenceText) >= legibilityMinimumNonWhitespaceCharacters else {
            return RequesterOrderEligibilityResult(eligible: false, category: nil)
        }
        // Checkout/review is classified first so a checkout screenshot is never
        // admitted as "cart" merely because it also carries a cart phrase.
        if isCheckoutReview(normalizedLines(evidenceText)) {
            return RequesterOrderEligibilityResult(eligible: true, category: .checkout)
        }
        let normalized = ScreenshotJSText.normalized(evidenceText)
        if cartChromeCount(normalized) >= 1 {
            return RequesterOrderEligibilityResult(eligible: true, category: .cart)
        }
        let detailedHistoryCore =
            ScreenshotJSText.hasMatch(viewOrder, in: normalized)
            && ScreenshotJSText.hasMatch(orderInformation, in: normalized)
            && ScreenshotJSText.hasMatch(quantifiedItem, in: normalized)
        if detailedHistoryCore {
            return RequesterOrderEligibilityResult(eligible: true, category: .historical)
        }
        return RequesterOrderEligibilityResult(eligible: false, category: nil)
    }

    private static let minimumMealSwipeTotal = 1
    private static let maximumMealSwipeTotal = 5

    /// Explicit meal-swipe count from independent OCR evidence, or `nil` when
    /// the evidence is absent, conflicting, or outside the accepted 1...5
    /// bounds (fail closed).
    static func corroboratedMealSwipeCount(_ evidenceText: String) -> Int? {
        let observed = ScreenshotJSText.matches(explicitMealSwipeTotal, in: evidenceText)
            .compactMap { $0[1].flatMap { Int($0) } }
        guard !observed.isEmpty else { return nil }
        guard !observed.contains(where: { $0 < minimumMealSwipeTotal || $0 > maximumMealSwipeTotal }) else {
            return nil
        }
        let aggregateTotals = Set(observed.filter { $0 > 1 })
        if aggregateTotals.count > 1 { return nil }
        if let only = aggregateTotals.first { return only }
        return observed.count <= maximumMealSwipeTotal ? observed.count : nil
    }

    static func hasExplicitMealSwipeNotation(_ evidenceText: String) -> Bool {
        ScreenshotJSText.hasMatch(explicitMealSwipeTotal, in: evidenceText)
    }

    /// Each validated quantity-one meal needs its own top-level OCR line.
    /// Callers enforce the resolved Meal Exchange path and absent M notation.
    static func inferredMealSwipeCount(mealItems: [MealItem], imageEvidenceTexts: [String]) -> Int? {
        guard (2...5).contains(mealItems.count) else { return nil }
        var names: [String] = []
        for item in mealItems {
            let normalized = ScreenshotJSText.normalized(item.name)
            guard normalized.utf16.starts(with: "1 ".utf16) else { return nil }
            names.append(String(normalized.dropFirst(2)))
        }
        if imageEvidenceTexts.count > 1 && Set(names).count != names.count { return nil }

        var candidates: [String] = []
        func isTopLevelName(_ name: String) -> Bool {
            guard let first = name.unicodeScalars.first else { return false }
            let bullets: Set<Unicode.Scalar> = ["*", "•", "●", "▪", "◦", "–", "—", "-"]
            return !bullets.contains(first)
        }
        for text in imageEvidenceTexts {
            let lines = normalizedLines(text)
            for index in lines.indices {
                let line = lines[index]
                if line.utf16.starts(with: "1 ".utf16) {
                    let name = String(line.dropFirst(2))
                    if isTopLevelName(name) { candidates.append(line) }
                }
                if ScreenshotJSText.literalEquals(line, "1"), index + 1 < lines.count,
                   isTopLevelName(lines[index + 1]) {
                    candidates.append("1 " + lines[index + 1])
                }
            }
        }
        var used = Set<Int>()
        // A shorter name can prefix a longer one; ground the specific line first.
        for name in names.sorted(by: { $0.utf16.count > $1.utf16.count }) {
            let prefix = "1 " + name
            guard let index = candidates.indices.first(where: { index in
                !used.contains(index) &&
                    (ScreenshotJSText.literalEquals(candidates[index], prefix) ||
                     candidates[index].utf16.starts(with: (prefix + " ").utf16))
            }) else { return nil }
            used.insert(index)
        }
        return names.count
    }

    /// The deterministic, order-level current-cart Dining Dollars estimate:
    /// a literal aggregate `3M + $2.00` expression alongside current-cart
    /// chrome, never alongside past-order language. Derived only from
    /// on-device evidence; it is never provider authority.
    static func currentCartDiningDollarsCents(_ evidenceText: String) -> Int? {
        let folded = ScreenshotJSText.asciiLowercased(evidenceText)
        guard ScreenshotJSText.hasMatch(currentCartMarkers, in: folded),
              !ScreenshotJSText.hasMatch(pastOrderMarkers, in: folded) else {
            return nil
        }
        struct Candidate: Hashable {
            let swipes: Int
            let cents: Int
        }
        let candidates: [Candidate] = ScreenshotJSText.matches(cartDollar, in: evidenceText).compactMap { groups in
            guard let swipes = groups[1].flatMap({ Int($0) }),
                  let dollars = groups[2].flatMap({ Int($0) }) else { return nil }
            let cents = groups.count > 3 ? (groups[3].flatMap { Int($0) } ?? 0) : 0
            return Candidate(swipes: swipes, cents: dollars * 100 + cents)
        }
        guard let first = candidates.first, Set(candidates).count == 1 else { return nil }
        guard first.swipes >= 1, first.swipes <= 5, first.cents > 0, first.cents <= 2_500 else { return nil }
        return first.cents
    }

    /// Evidence for the pre-existing Meal Exchange TOP-UP alone. A review's
    /// `3M + $2.00` never becomes a top-up; the new labeled whole-order Total
    /// rule is separate. Mirrors the backend's
    /// `amountAuthorityEvidenceText`.
    static func amountAuthorityEvidenceText(imageEvidenceTexts: [String]) -> String {
        imageEvidenceTexts
            .filter { evaluateEligibility($0).category != .checkout }
            .joined(separator: "\n")
    }

    // MARK: - Deterministic menu path (W4-R4.1)

    struct MenuPathResolution: Equatable {
        let menuPath: RequestMenuPath?
        /// Meal Exchange and Dining Dollars evidence are both present.
        let conflict: Bool

        static let noEvidence = MenuPathResolution(menuPath: nil, conflict: false)
    }

    private enum PaymentRowState {
        case none
        case diningDollars
        case mealExchange
        case other
    }

    private static func isTrailingAffordance(_ scalar: Unicode.Scalar) -> Bool {
        ScreenshotJSText.isWhitespace(scalar)
            || [">", "\u{203A}", "\u{00BB}", "\u{276F}", "\u{2329}", "\u{232A}", "\u{3009}", "\u{2192}"]
                .contains(scalar)
    }

    /// `value.replace(/[\s>›»❯〈〉〉→]+$/, "")`.
    private static func strippingTrailingAffordance(_ value: String) -> String {
        var scalars = Array(value.unicodeScalars)
        while let last = scalars.last, isTrailingAffordance(last) { scalars.removeLast() }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    private static func selectedTender(_ value: String) -> PaymentRowState? {
        if ScreenshotJSText.literalEquals(strippingTrailingAffordance(value), diningDollarsValue) {
            return .diningDollars
        }
        return ScreenshotJSText.hasMatch(mealPayment, in: value) ? .mealExchange : nil
    }

    /// An observation may be crossed only if it has no independent payment or
    /// structural authority. Its text never contributes evidence to the path.
    private static func inertPaymentObservation(_ lines: [String], _ index: Int) -> Bool {
        let line = lines[index]
        return departureAt(lines, index) == nil && paymentRow(lines, index) == nil
            && selectedTender(line) == nil
            && !ScreenshotJSText.hasMatch(otherTender, in: line)
            && !ScreenshotJSText.hasMatch(mixedTender, in: line)
            && !ScreenshotJSText.hasMatch(splitTender, in: line)
            && !ScreenshotJSText.hasMatch(diningTenderAmount, in: line)
            && !ScreenshotJSText.hasMatch(otherTenderAmount, in: line)
            && !ScreenshotJSText.hasMatch(explicitMealExchange, in: line)
            && !hasExplicitMealSwipeNotation(line)
            && !ScreenshotJSText.hasMatch(totalWithAmount, in: line)
            && !ScreenshotJSText.literalEquals(line, "total")
            && !ScreenshotJSText.hasMatch(amountOnly, in: line)
    }

    private static func checkoutPaymentRowState(_ lines: [String]) -> PaymentRowState {
        let rows = paymentRows(lines)
        if rows.isEmpty { return .none }
        guard rows.count == 1, let row = rows.first, let payment = paymentSection(lines),
              payment.contains(row.index), row.index + row.span <= payment.upperBound else { return .other }
        let valueIndex = row.index + row.span
        var tender = row.remainder.isEmpty ? nil : selectedTender(row.remainder)
        var tenderIndex = row.remainder.isEmpty ? valueIndex : row.index
        if row.remainder.isEmpty {
            guard valueIndex < payment.upperBound else { return .other }
            tender = selectedTender(lines[valueIndex])
            if tender == nil, inertPaymentObservation(lines, valueIndex),
               valueIndex + 1 < payment.upperBound {
                tenderIndex = valueIndex + 1
                tender = selectedTender(lines[tenderIndex])
            }
        }
        guard let tender else { return .other }

        // Exactly one recognized tender belongs to this row. Another
        // canonical value, known tender, or split payment fails closed.
        let recognized = payment.filter { index in
            if index == row.index { return !row.remainder.isEmpty && selectedTender(row.remainder) != nil }
            return selectedTender(lines[index]) != nil
        }
        if recognized.count != 1 || recognized[0] != tenderIndex
            || payment.contains(where: { index in
                ScreenshotJSText.hasMatch(otherTender, in: lines[index])
                    || ScreenshotJSText.hasMatch(mixedTender, in: lines[index])
                    || ScreenshotJSText.hasMatch(splitTender, in: lines[index])
            })
            || (payment.upperBound < lines.count
                && ScreenshotJSText.hasMatch(otherTender, in: lines[payment.upperBound])) {
            return .other
        }
        return tender
    }

    /// Exact order-level Total on eligible current cart/review evidence.
    /// A conflicting final Total, ambiguous split payment, historical screen,
    /// or any unlabeled dollar figure cannot supply an estimate.
    private static func textOnlyCurrentOrderTotalCents(
        imageEvidenceTexts: [String],
        withinEstimateBounds: Bool = true
    ) -> Int? {
        var totals: [Int] = []
        var diningTenderAmountFound = false
        var otherTenderAmountFound = false
        for text in imageEvidenceTexts {
            let eligibility = evaluateEligibility(text)
            guard eligibility.eligible, eligibility.category != .historical else { continue }
            let lines = normalizedLines(text)
            if lines.contains(where: { ScreenshotJSText.hasMatch(splitTender, in: $0) }) { return nil }
            diningTenderAmountFound = diningTenderAmountFound
                || lines.contains(where: { ScreenshotJSText.hasMatch(diningTenderAmount, in: $0) })
            otherTenderAmountFound = otherTenderAmountFound
                || lines.contains(where: { ScreenshotJSText.hasMatch(otherTenderAmount, in: $0) })
            if eligibility.category == .checkout {
                switch checkoutPaymentRowState(lines) {
                case .other, .mealExchange: return nil
                case .none, .diningDollars: break
                }
            }
            for index in lines.indices {
                let line = lines[index]
                let groups = ScreenshotJSText.matches(totalWithAmount, in: line).first
                    ?? (ScreenshotJSText.literalEquals(line, "total") && index + 1 < lines.count
                        ? ScreenshotJSText.matches(amountOnly, in: lines[index + 1]).first : nil)
                if ScreenshotJSText.literalEquals(line, "total"), groups == nil { return nil }
                guard let groups,
                      let dollars = groups[1].flatMap(Int.init) else { continue }
                totals.append(dollars * 100 + (groups[2].flatMap(Int.init) ?? 0))
            }
        }
        guard !(diningTenderAmountFound && otherTenderAmountFound),
              let first = totals.first, Set(totals).count == 1 else { return nil }
        return !withinEstimateBounds || (1...5_000).contains(first) ? first : nil
    }

    private static func normalizedObservationLines(_ text: String) -> [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        var previousWasCR = false
        func flush() {
            lines.append(ScreenshotJSText.normalized(String(current)))
            current = String.UnicodeScalarView()
        }
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                if previousWasCR { previousWasCR = false; continue }
                flush()
            } else if scalar == "\r" {
                flush()
                previousWasCR = true
                continue
            } else {
                current.append(scalar)
            }
            previousWasCR = false
        }
        flush()
        return lines
    }

    private struct ExpectedGeometryObservation {
        let id: Int
        let classification: ScreenshotTotalGeometryEvidence.Classification
        let cents: Int?
    }

    /// Validates all text-derived facts and the completeness of the relation
    /// matrix. The two spatial booleans are the only facts trusted from the
    /// client-side Vision derivation; raw boxes are intentionally unavailable.
    private static func validatedGeometryTotal(
        evidenceText: String,
        evidence: ScreenshotTotalGeometryEvidence?
    ) -> Int? {
        guard let evidence else { return nil }
        let expected: [ExpectedGeometryObservation] = normalizedObservationLines(evidenceText)
            .enumerated().compactMap { id, line in
                if ScreenshotJSText.literalEquals(line, "total") {
                    return ExpectedGeometryObservation(id: id, classification: .totalLabel, cents: nil)
                }
                guard let groups = ScreenshotJSText.matches(amountOnly, in: line).first,
                      let dollars = groups[1].flatMap(Int.init) else { return nil }
                return ExpectedGeometryObservation(
                    id: id,
                    classification: .amount,
                    cents: dollars * 100 + (groups[2].flatMap(Int.init) ?? 0)
                )
            }
        guard evidence.observations.count == expected.count else { return nil }

        var byID: [Int: ScreenshotTotalGeometryEvidence.Observation] = [:]
        for observation in evidence.observations {
            guard byID[observation.id] == nil else { return nil }
            byID[observation.id] = observation
        }
        for item in expected {
            guard let supplied = byID[item.id], supplied.classification == item.classification,
                  supplied.geometryValid else { return nil }
            switch item.classification {
            case .totalLabel:
                guard supplied.cents == nil else { return nil }
            case .amount:
                guard supplied.cents == item.cents else { return nil }
            }
        }

        let totalIDs = expected.filter { $0.classification == .totalLabel }.map(\.id)
        let amountIDs = expected.filter { $0.classification == .amount }.map(\.id)
        guard totalIDs.count == 1 else { return nil }
        let expectedPairs = Set(totalIDs.flatMap { totalID in
            amountIDs.map { amountID in "\(totalID):\(amountID)" }
        })
        guard evidence.relations.count == expectedPairs.count else { return nil }

        var seenPairs = Set<String>()
        var qualifyingAmountID: Int?
        for relation in evidence.relations {
            let key = "\(relation.totalObservationID):\(relation.amountObservationID)"
            guard expectedPairs.contains(key), seenPairs.insert(key).inserted else { return nil }
            if relation.sameRow && relation.rightOf {
                guard qualifyingAmountID == nil else { return nil }
                qualifyingAmountID = relation.amountObservationID
            }
        }
        guard let qualifyingAmountID,
              let amount = byID[qualifyingAmountID], amount.classification == .amount else { return nil }
        return amount.cents
    }

    /// Existing valid text-only association wins unchanged. Only its failure
    /// opens the bounded geometry fallback.
    static func currentOrderTotalCents(
        imageEvidenceTexts: [String],
        withinEstimateBounds: Bool = true,
        imageTotalGeometryEvidence: [ScreenshotTotalGeometryEvidence?] = []
    ) -> Int? {
        if let textOnly = textOnlyCurrentOrderTotalCents(
            imageEvidenceTexts: imageEvidenceTexts,
            withinEstimateBounds: withinEstimateBounds
        ) {
            return textOnly
        }

        var totals: [Int] = []
        var diningTenderAmountFound = false
        var otherTenderAmountFound = false
        for (imageIndex, text) in imageEvidenceTexts.enumerated() {
            let eligibility = evaluateEligibility(text)
            guard eligibility.eligible, eligibility.category != .historical else { continue }
            let lines = normalizedLines(text)
            if lines.contains(where: { ScreenshotJSText.hasMatch(splitTender, in: $0) }) { return nil }
            diningTenderAmountFound = diningTenderAmountFound
                || lines.contains(where: { ScreenshotJSText.hasMatch(diningTenderAmount, in: $0) })
            otherTenderAmountFound = otherTenderAmountFound
                || lines.contains(where: { ScreenshotJSText.hasMatch(otherTenderAmount, in: $0) })
            if eligibility.category == .checkout {
                switch checkoutPaymentRowState(lines) {
                case .other, .mealExchange: return nil
                case .none, .diningDollars: break
                }
            }

            let totalsBeforeImage = totals.count
            var needsGeometry = false
            for index in lines.indices {
                let line = lines[index]
                if let groups = ScreenshotJSText.matches(totalWithAmount, in: line).first,
                   let dollars = groups[1].flatMap(Int.init) {
                    totals.append(dollars * 100 + (groups[2].flatMap(Int.init) ?? 0))
                } else if ScreenshotJSText.literalEquals(line, "total") {
                    let adjacent = index + 1 < lines.count
                        ? ScreenshotJSText.matches(amountOnly, in: lines[index + 1]).first : nil
                    if let adjacent, let dollars = adjacent[1].flatMap(Int.init) {
                        totals.append(dollars * 100 + (adjacent[2].flatMap(Int.init) ?? 0))
                    } else {
                        needsGeometry = true
                    }
                }
            }
            if needsGeometry {
                guard totals.count == totalsBeforeImage else { return nil }
                let geometry = imageIndex < imageTotalGeometryEvidence.count
                    ? imageTotalGeometryEvidence[imageIndex] : nil
                guard let cents = validatedGeometryTotal(evidenceText: text, evidence: geometry) else {
                    return nil
                }
                totals.append(cents)
            }
        }
        guard !(diningTenderAmountFound && otherTenderAmountFound),
              let first = totals.first, Set(totals).count == 1 else { return nil }
        return !withinEstimateBounds || (1...5_000).contains(first) ? first : nil
    }

    /// The deterministic menu path for one logical selection, from each
    /// eligible screenshot's own independent on-device OCR text — never from
    /// provider output or venue plausibility. Meal Exchange: provider
    /// venue/menu identity, bounded `1M`–`5M`, or meal-based payment wording.
    /// With a checkout row, the selected wording must be uniquely attributable.
    /// Dining Dollars: selected review payment row or bounded current cart
    /// with one labeled order Total and no Meal Exchange evidence. Both
    /// present is a conflict.
    /// Port of `resolveMenuPath` (`src/screenshotEligibility.ts`).
    static func resolveMenuPath(
        imageEvidenceTexts: [String],
        imageTotalGeometryEvidence: [ScreenshotTotalGeometryEvidence?] = []
    ) -> MenuPathResolution {
        let eligible = imageEvidenceTexts.filter { evaluateEligibility($0).eligible }
        let hasAnyExplicitM = eligible.contains { hasExplicitMealSwipeNotation($0) }

        var mealExchangeEvidence = false
        var diningDollarsRows = 0
        var otherPaymentRows = 0
        var currentCartWithTotal = false
        for (imageIndex, text) in imageEvidenceTexts.enumerated()
        where evaluateEligibility(text).eligible {
            let lines = normalizedLines(text)
            let category = evaluateEligibility(text).category
            if hasMealExchangeIdentity(lines)
                || ((category != .checkout || paymentRows(lines).isEmpty)
                    && lines.contains(where: { ScreenshotJSText.hasMatch(mealPayment, in: $0) })) {
                mealExchangeEvidence = true
            }
            if category == .cart,
               !hasMealExchangeIdentity(lines),
               !hasExplicitMealSwipeNotation(text),
               !lines.contains(where: { ScreenshotJSText.hasMatch(mealPayment, in: $0) }),
               currentOrderTotalCents(
                   imageEvidenceTexts: [text],
                   withinEstimateBounds: false,
                   imageTotalGeometryEvidence: [
                       imageIndex < imageTotalGeometryEvidence.count
                           ? imageTotalGeometryEvidence[imageIndex] : nil
                   ]
               ) != nil {
                currentCartWithTotal = true
            }
            if category == .checkout {
                switch checkoutPaymentRowState(lines) {
                case .diningDollars: diningDollarsRows += 1
                case .mealExchange: mealExchangeEvidence = true
                case .other: otherPaymentRows += 1
                case .none: break
                }
            }
        }
        if corroboratedMealSwipeCount(eligible.joined(separator: "\n")) != nil {
            mealExchangeEvidence = true
        }

        let diningDollarsEvidence =
            (diningDollarsRows > 0 && otherPaymentRows == 0)
            || (currentCartWithTotal && otherPaymentRows == 0
                && currentOrderTotalCents(
                    imageEvidenceTexts: imageEvidenceTexts,
                    withinEstimateBounds: false,
                    imageTotalGeometryEvidence: imageTotalGeometryEvidence
                ) != nil
                // Unresolved M elsewhere cannot grant the cart path. An
                // independently established Meal Exchange signal still
                // exposes the existing cross-image conflict.
                && (!hasAnyExplicitM || mealExchangeEvidence))
        if mealExchangeEvidence && diningDollarsEvidence {
            return MenuPathResolution(menuPath: nil, conflict: true)
        }
        if mealExchangeEvidence { return MenuPathResolution(menuPath: .mealExchange, conflict: false) }
        if diningDollarsEvidence { return MenuPathResolution(menuPath: .diningDollars, conflict: false) }
        return .noEvidence
    }

    // MARK: - Vendor grounding

    private static func matchesVendorText(_ normalized: String, _ vendor: DiningSpot) -> Bool {
        let full = vendor.name.lowercased()
        let base = ScreenshotJSText.trimmed(full.components(separatedBy: " - ").first ?? full)
        return ScreenshotJSText.literalEquals(normalized, full)
            || ScreenshotJSText.literalEquals(normalized, base)
            || ScreenshotJSText.literalContains(normalized, full)
    }

    /// Catalog entries named by `text`. A base label shared by two entries
    /// (the two current Upstein entries) matches both, which is what makes a
    /// bare shared label ambiguous rather than a match.
    static func groundedVendorMatches(_ text: String?, vendors: [DiningSpot]) -> [DiningSpot] {
        guard let text, !text.isEmpty else { return [] }
        let normalized = ScreenshotJSText.normalized(text)
        guard !normalized.isEmpty else { return [] }
        return vendors.filter { matchesVendorText(normalized, $0) }
    }

    /// The one catalog vendor grounded in independent evidence, or `nil`. A
    /// provider's own venue text can only veto a disagreement; it can never
    /// select a vendor by itself.
    static func resolveVendor(
        evidenceText: String,
        visibleVenueText: String?,
        vendors: [DiningSpot]
    ) -> DiningSpot? {
        let groundedMatches = groundedVendorMatches(evidenceText, vendors: vendors)
        let groundedNames = Set(groundedMatches.map(\.name))
        guard groundedNames.count == 1, let grounded = groundedMatches.first else { return nil }

        if let visibleVenueText, !visibleVenueText.isEmpty {
            let providerNames = Set(groundedVendorMatches(visibleVenueText, vendors: vendors).map(\.name))
            if !providerNames.isEmpty, !providerNames.contains(grounded.name) {
                return nil
            }
        }
        return grounded
    }
}
