//
//  ScreenshotSelection.swift
//  CommonPlateios
//
// W4-S3: the shared runtime's one logical input — the complete, ORDERED
// screenshot selection. It is pixels only. Recognized text, layout, regions,
// and any other derived representation are deliberately NOT part of this
// contract: workflow and provider adapters derive whatever they need from these
// pixels, privately, and the runtime never sees it. Content-bearing and
// in-memory only; nothing here is persisted, logged, or sent by this file.
import Foundation

/// One selected screenshot, prepared on device.
struct ScreenshotPreparedImage: Equatable {
    /// The screenshot exactly as it was selected. An adapter that derives text,
    /// layout, or geometry decodes this, never the normalized bytes, so
    /// derivation fidelity is not reduced by normalization.
    let sourceData: Data
    /// Bounded-size normalized bytes (`ScreenshotImageNormalizer`) for any
    /// provider that takes the image itself.
    let data: Data
    let mimeType: String
}

/// The whole selection for one logical analysis, in selection order. A provider
/// may reason across every item jointly; nothing here implies per-image
/// extraction.
struct ScreenshotSelection: Equatable {
    struct Item: Equatable {
        /// Zero-based position in the ORIGINAL selection. Retained by every
        /// subset, so a citation of "screenshot 2" always means the same
        /// screenshot the requester chose second.
        let index: Int
        let image: ScreenshotPreparedImage
    }

    /// In selection order. Never reordered by the runtime.
    let items: [Item]

    var count: Int { items.count }

    /// `nil` for an empty selection. The position of an image in `images` is
    /// its selection order.
    init?(images: [ScreenshotPreparedImage]) {
        guard !images.isEmpty else { return nil }
        items = images.enumerated().map { Item(index: $0.offset, image: $0.element) }
    }

    private init(items: [Item]) {
        self.items = items
    }

    /// The items whose original indices are in `indices`, still in selection
    /// order and still carrying their original indices; `nil` if none remain.
    func retaining(_ indices: Set<Int>) -> ScreenshotSelection? {
        let kept = items.filter { indices.contains($0.index) }
        return kept.isEmpty ? nil : ScreenshotSelection(items: kept)
    }
}
