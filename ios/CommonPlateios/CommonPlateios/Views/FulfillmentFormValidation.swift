//
//  FulfillmentFormValidation.swift
//  CommonPlateios
//

import Foundation

/// The helper form's editable values. It remains private to the fulfillment
/// screen's workflow and is never shared with request creation or the store.
struct FulfillmentFormDraft: Equatable {
    var orderNumber: String
    var eta: String
    /// W4-H1: `nil` until the helper chooses a Pickup ETA. The field is
    /// required, so no choice is preselected on the helper's behalf.
    var readyTime: FulfillmentReadyTime?
    var contactMessage: String

    // W4-H1a: the placed-order screenshot is deliberately NOT part of this
    // view-local draft. Its pre-submit selection is owned by `RequestStore`'s
    // private in-memory state (`selectPlacedOrderScreenshot`), and the view
    // reads only whether one is selected.

    init(
        orderNumber: String = "",
        eta: String = "",
        readyTime: FulfillmentReadyTime? = nil,
        contactMessage: String = ""
    ) {
        self.orderNumber = orderNumber
        self.eta = eta
        self.readyTime = readyTime
        self.contactMessage = contactMessage
    }
}

/// The reservation form's locally-checkable fields, listed in the order they
/// appear on screen — which is also the order the first invalid one is focused
/// in after a rejected submit.
///
/// Ready time is deliberately absent: it is a picker over a fixed set of
/// choices, so it cannot hold an invalid value — only no value yet, which keeps
/// `Finish helping` disabled rather than producing a message.
/// The helper's email is absent for a different reason (W3-I1): it is no longer
/// a field at all, because the helper is the verified participant the
/// reservation is already bound to.
enum FulfillmentFormField: Hashable, CaseIterable {
    case orderNumber
}

/// One local validation failure, carrying the field it belongs to so the message
/// can be rendered against that field instead of arriving as a form-level
/// failure the helper has to decode.
struct FulfillmentFieldError: Equatable, Identifiable {
    let field: FulfillmentFormField
    let message: String

    var id: FulfillmentFormField { field }
}

/// Independent presentation history for the fulfillment form. Only fields
/// whose own error has been shown are allowed to revalidate live; a rejected
/// sibling field never makes an untouched field noisy during initial typing.
struct FulfillmentValidationPresentation: Equatable {
    private(set) var presentedFields: Set<FulfillmentFormField> = []

    mutating func presentInvalidField(
        _ field: FulfillmentFormField,
        from errors: [FulfillmentFieldError]
    ) {
        guard errors.contains(where: { $0.field == field }) else { return }
        presentedFields.insert(field)
    }

    mutating func presentAll(_ errors: [FulfillmentFieldError]) {
        presentedFields.formUnion(errors.map(\.field))
    }

    /// The exact focus transition used by `FulfillRequestView`. It has no
    /// submission dependency and cannot touch store-owned lifecycle state.
    mutating func handleFocusTransition(
        from previousField: FulfillmentFormField?,
        to currentField: FulfillmentFormField?,
        errors: [FulfillmentFieldError]
    ) {
        guard previousField != currentField, let previousField else { return }
        presentInvalidField(previousField, from: errors)
    }

    func visibleErrors(from errors: [FulfillmentFieldError]) -> [FulfillmentFieldError] {
        errors.filter { presentedFields.contains($0.field) }
    }
}

struct FulfillmentSubmissionValues: Equatable {
    let orderNumber: String
    let eta: String
    let contactMessage: String?
}

struct FulfillmentSubmissionResult: Equatable {
    let presentation: FulfillmentValidationPresentation
    let firstInvalidTextField: FulfillmentFormField?
    let didSubmit: Bool
}

/// Mirrors the backend's order-number rule so locally knowable errors can be
/// attached to fields. The backend remains authoritative.
enum FulfillmentFormValidator {
    static let emptyOrderNumberMessage = "Enter the Grubhub order number."
    static let nonNumericOrderNumberMessage = "Use numbers only."
    static let longOrderNumberMessage = "Use 50 digits or fewer."

    /// Backend: `orderNumber: z.string().trim().min(1).regex(/^[0-9]{1,50}$/)`.
    /// Split into its two halves here so each failure can be named separately —
    /// the backend answers both with one opaque code, but "too long" and "not a
    /// number" are different mistakes and need different corrections.
    private static let orderNumberDigitsPattern = "^[0-9]+$"
    static let orderNumberMaximumLength = 50

    /// The app's one email shape rule, kept here because `NYUEmailPolicy` and
    /// the participant verification form both use it. It is no longer applied
    /// to a fulfillment field — there is none — but it remains the single
    /// definition of a well-formed address, and a second copy would be a second
    /// idea of one.
    private static let emailPattern = "^[^\\s@]+@[^\\s@]+\\.[^\\s@]{2,}$"

    /// Every local failure, in field order. Empty means the submit may proceed
    /// as far as the network; the store's own gates still decide from there.
    static func validate(orderNumber: String) -> [FulfillmentFieldError] {
        var errors: [FulfillmentFieldError] = []
        if let message = orderNumberError(orderNumber) {
            errors.append(
                FulfillmentFieldError(field: .orderNumber, message: message)
            )
        }
        return errors
    }

    static func isValidEmail(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return matches(trimmed, emailPattern)
    }

    /// Precedence is empty, then too long, then non-numeric. A value that breaks
    /// both the length and the digits rule is reported as too long: shortening
    /// it is the correction that has to happen first, and a helper told "use
    /// numbers only" about a 60-character entry would fix the characters and be
    /// refused again.
    static func orderNumberError(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return emptyOrderNumberMessage
        }
        if trimmed.count > orderNumberMaximumLength {
            return longOrderNumberMessage
        }
        return matches(trimmed, orderNumberDigitsPattern) ? nil : nonNumericOrderNumberMessage
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}
