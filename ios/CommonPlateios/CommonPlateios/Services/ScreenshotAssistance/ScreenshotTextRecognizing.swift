//
//  ScreenshotTextRecognizing.swift
//  CommonPlateios
//
// W4-S3: on-device Vision OCR as a shared SERVICE that adapters may call. It is
// not part of the runtime's input contract: the shared input is the ordered
// pixel selection, and a workflow or provider adapter that wants recognized text
// asks for it here. Nothing here leaves the device, persists, or logs content.
import UIKit

/// Privacy-safe, per-image evidence derived from Vision observations before
/// their raw normalized boxes are discarded. Observation identifiers are the
/// recognized-line indexes in `text`, so the backend can validate every class
/// and amount against the already-authorized `localEvidenceText` without ever
/// receiving coordinates.
struct ScreenshotTotalGeometryEvidence: Codable, Equatable {
    enum Classification: String, Codable, Equatable {
        case totalLabel = "total-label"
        case amount
    }

    struct Observation: Codable, Equatable {
        let id: Int
        let classification: Classification
        let cents: Int?
        let geometryValid: Bool
    }

    struct Relation: Codable, Equatable {
        let totalObservationID: Int
        let amountObservationID: Int
        let sameRow: Bool
        let rightOf: Bool
    }

    let observations: [Observation]
    /// Complete Total-label × amount-candidate matrix for this image.
    let relations: [Relation]
}

struct ScreenshotRecognizedText: Equatable {
    let text: String
    let totalGeometryEvidence: ScreenshotTotalGeometryEvidence?

    init(text: String, totalGeometryEvidence: ScreenshotTotalGeometryEvidence? = nil) {
        self.text = text
        self.totalGeometryEvidence = totalGeometryEvidence
    }
}

protocol ScreenshotTextRecognizing {
    /// The recognized lines of `image`, joined with newlines in the order
    /// Vision reports them; empty when nothing is recognizable.
    func recognizeText(in image: ScreenshotPreparedImage) async -> String

    /// Rich recognition used by Requester Screenshot Assistance. The default
    /// preserves every existing synthetic/test recognizer as text-only.
    func recognize(in image: ScreenshotPreparedImage) async -> ScreenshotRecognizedText
}

extension ScreenshotTextRecognizing {
    func recognize(in image: ScreenshotPreparedImage) async -> ScreenshotRecognizedText {
        ScreenshotRecognizedText(text: await recognizeText(in: image))
    }
}

/// Apple Vision OCR (`ScreenshotLocalTextRecognizer`) run against the
/// screenshot as it was selected, before normalization, for the best
/// recognition fidelity.
struct VisionScreenshotTextRecognizer: ScreenshotTextRecognizing {
    func recognizeText(in image: ScreenshotPreparedImage) async -> String {
        await recognize(in: image).text
    }

    func recognize(in image: ScreenshotPreparedImage) async -> ScreenshotRecognizedText {
        guard let uiImage = UIImage(data: image.sourceData) else {
            return ScreenshotRecognizedText(text: "")
        }
        return await ScreenshotLocalTextRecognizer.recognize(in: uiImage)
    }
}
