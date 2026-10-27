//
//  ScreenshotInputPreparer.swift
//  CommonPlateios
//
// W4-S3: shared image preparation — decode and bounded normalization
// (`ScreenshotImageNormalizer`) — extracted from `RequestFoodView` so every
// consumer prepares a screenshot identically. It produces pixels only: any
// text/layout/region derivation is a workflow or provider adapter's job (see
// `ScreenshotWorkflow`, `ScreenshotTextRecognizing`). Nothing here leaves the
// device, persists, or logs content; the image bytes live only in the returned
// value.
import UIKit

enum ScreenshotInputPreparer {
    /// Prepares one selected screenshot: it must decode and normalize.
    ///
    /// `isStillCurrent` is re-checked after normalization; returning `nil`
    /// means the image failed to decode/normalize or the attempt was retired
    /// (superseded, Off, or left) — the caller abandons the whole attempt
    /// rather than analyzing a subset of what the requester chose.
    @MainActor
    static func prepare(
        imageData: Data,
        isStillCurrent: () -> Bool
    ) -> ScreenshotPreparedImage? {
        guard let uiImage = UIImage(data: imageData),
              let normalized = ScreenshotImageNormalizer.normalize(uiImage) else {
            return nil
        }
        guard isStillCurrent() else { return nil }

        return ScreenshotPreparedImage(
            sourceData: imageData,
            data: normalized.data,
            mimeType: normalized.mimeType
        )
    }
}
