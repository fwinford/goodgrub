//
//  ScreenshotLocalTextRecognizer.swift
//  CommonPlateios
//
// W4-S1 independent evidence source. Apple Vision — a different, local,
// non-LLM OCR engine — is run on the selected screenshot before it is ever
// sent to OpenAI, and its output is the only text `screenshotProposalRoute.ts`
// trusts for eligibility and meal-swipe corroboration. OpenAI's own output
// is never used to validate itself: asking the same model that produced a
// claim to also produce the evidence that claim is checked against is not
// independent corroboration.
import UIKit
import Vision

enum ScreenshotLocalTextRecognizer {
    /// Raw Vision output exists only long enough to construct the flattened
    /// text and the minimal relation evidence below. This type is never
    /// Codable and never crosses the on-device recognition boundary.
    struct Observation {
        let text: String
        let boundingBox: CGRect?
    }

    /// Recognizes all visible text in `image` using on-device Vision OCR.
    /// Returns the recognized lines joined with newlines, in the order
    /// Vision reports them; an image with no recognizable text returns an
    /// empty string, which the backend's own legibility threshold simply
    /// rejects as ineligible rather than this method treating it specially.
    static func recognizeText(in image: UIImage) async -> String {
        await recognize(in: image).text
    }

    static func recognize(in image: UIImage) async -> ScreenshotRecognizedText {
        guard let cgImage = image.cgImage else { return ScreenshotRecognizedText(text: "") }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let recognized = observations.compactMap { observation -> Observation? in
                    guard let text = observation.topCandidates(1).first?.string else { return nil }
                    return Observation(text: text, boundingBox: observation.boundingBox)
                }
                continuation.resume(returning: derive(from: recognized))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: ScreenshotRecognizedText(text: ""))
            }
        }
    }

    /// Production same-row/right-side rule. Vision boxes are normalized to
    /// the image with a lower-left origin; overlap and left/right ordering are
    /// invariant to that origin choice. "Same row" requires at least 50%
    /// vertical overlap of the shorter box, and "right side" requires the
    /// amount's left edge not to precede the Total label's right edge. There
    /// is no ranking, nearest-neighbor, index, or price heuristic.
    static func derive(from observations: [Observation]) -> ScreenshotRecognizedText {
        let text = observations.map(\.text).joined(separator: "\n")
        var relevant: [ScreenshotTotalGeometryEvidence.Observation] = []
        var boxesByID: [Int: CGRect?] = [:]
        var totalIDs: [Int] = []
        var amountIDs: [Int] = []

        for (id, observation) in observations.enumerated() {
            let normalized = ScreenshotJSText.normalized(observation.text)
            let box = observation.boundingBox
            let valid = box.map(validGeometry) ?? false
            if ScreenshotJSText.literalEquals(normalized, "total") {
                relevant.append(.init(
                    id: id, classification: .totalLabel, cents: nil, geometryValid: valid
                ))
                boxesByID[id] = box
                totalIDs.append(id)
            } else if let cents = amountCents(normalized) {
                relevant.append(.init(
                    id: id, classification: .amount, cents: cents, geometryValid: valid
                ))
                boxesByID[id] = box
                amountIDs.append(id)
            }
        }

        guard !totalIDs.isEmpty else { return ScreenshotRecognizedText(text: text) }
        var relations: [ScreenshotTotalGeometryEvidence.Relation] = []
        for totalID in totalIDs {
            for amountID in amountIDs {
                let totalBox = boxesByID[totalID] ?? nil
                let amountBox = boxesByID[amountID] ?? nil
                let valid = totalBox.map(validGeometry) == true && amountBox.map(validGeometry) == true
                relations.append(.init(
                    totalObservationID: totalID,
                    amountObservationID: amountID,
                    sameRow: valid && sameRow(totalBox!, amountBox!),
                    rightOf: valid && amountBox!.minX >= totalBox!.maxX
                ))
            }
        }
        return ScreenshotRecognizedText(
            text: text,
            totalGeometryEvidence: ScreenshotTotalGeometryEvidence(
                observations: relevant,
                relations: relations
            )
        )
    }

    nonisolated private static func validGeometry(_ box: CGRect) -> Bool {
        [box.minX, box.minY, box.width, box.height, box.maxX, box.maxY].allSatisfy(\.isFinite)
            && box.width > 0 && box.height > 0
            && box.minX >= 0 && box.minY >= 0
            && box.maxX <= 1 && box.maxY <= 1
    }

    private static func sameRow(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let overlap = max(0, min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY))
        guard overlap > 0 else { return false }
        let shorter = min(lhs.height, rhs.height)
        // Only absorbs binary floating-point error at the exact 50% boundary;
        // the allowance scales with that boundary rather than normalized space.
        let threshold = shorter * 0.5
        let roundingTolerance = threshold.ulp * 16
        return overlap >= threshold - roundingTolerance
    }

    private static func amountCents(_ text: String) -> Int? {
        guard text.first == "$" else { return nil }
        let pieces = text.dropFirst().split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 1 || pieces.count == 2,
              let dollarsText = pieces.first,
              (1...4).contains(dollarsText.count),
              dollarsText.allSatisfy({ $0.isASCII && $0.isNumber }),
              let dollars = Int(dollarsText) else { return nil }
        if pieces.count == 1 { return dollars * 100 }
        let centsText = pieces[1]
        guard centsText.count == 2,
              centsText.allSatisfy({ $0.isASCII && $0.isNumber }),
              let cents = Int(centsText) else { return nil }
        return dollars * 100 + cents
    }
}
