//
//  ScreenshotEvidence.swift
//  CommonPlateios
//
// W4-S3: the optional, schema-neutral evidence/provenance representation. A
// proposed field may cite one or more screenshots; each citation may carry the
// exact source text and an optional normalized region. It is:
//
// - optional: a provider may omit it unless its schema's validator requires it;
// - schema-neutral: fields are named by opaque, schema-defined keys, so this
//   file knows no workflow's fields;
// - in-memory only: it is returned beside a validated outcome, released with
//   the analysis attempt, never persisted, and never telemetry content.
//
// S3 decides nothing about whether any UI displays it; that belongs to the
// consuming slice.
import Foundation

/// A normalized rectangle inside one screenshot: origin at the top-left, every
/// value within `0...1`. `nil` for anything that is not a real region.
struct ScreenshotEvidenceRegion: Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init?(x: Double, y: Double, width: Double, height: Double) {
        let values = [x, y, width, height]
        guard values.allSatisfy({ $0.isFinite }),
              x >= 0, y >= 0, width > 0, height > 0,
              x + width <= 1, y + height <= 1 else {
            return nil
        }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// One citation: which screenshot, the exact text seen there, and optionally
/// where.
struct ScreenshotEvidenceEntry: Equatable {
    /// Original selection index (`ScreenshotSelection.Item.index`).
    let screenshotIndex: Int
    let sourceText: String
    let region: ScreenshotEvidenceRegion?

    init(screenshotIndex: Int, sourceText: String, region: ScreenshotEvidenceRegion? = nil) {
        self.screenshotIndex = screenshotIndex
        self.sourceText = sourceText
        self.region = region
    }
}

/// Citations by schema-defined field key. One field may cite several
/// screenshots, in order.
struct ScreenshotEvidenceSet: Equatable {
    private(set) var entriesByField: [String: [ScreenshotEvidenceEntry]]

    static let empty = ScreenshotEvidenceSet()

    init(entriesByField: [String: [ScreenshotEvidenceEntry]] = [:]) {
        self.entriesByField = entriesByField.filter { !$0.value.isEmpty }
    }

    var isEmpty: Bool { entriesByField.isEmpty }

    var fieldKeys: Set<String> { Set(entriesByField.keys) }

    func entries(for field: String) -> [ScreenshotEvidenceEntry] {
        entriesByField[field] ?? []
    }
}
