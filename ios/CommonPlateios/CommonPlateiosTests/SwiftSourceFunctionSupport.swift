//
//  SwiftSourceFunctionSupport.swift
//  CommonPlateiosTests
//
// Source-structure tests need to assert facts about ONE function, not about a
// file that merely contains the right strings somewhere. This extracts a
// function's body by brace matching (skipping line comments and single-line
// string literals) so an assertion cannot pass because the same text appears
// in an unrelated function.
import Foundation

enum SwiftSourceFunction {
    /// The text between the opening `{` that follows `signature` and its
    /// matching `}`, or nil when the signature is absent or unbalanced.
    static func body(startingWith signature: String, in source: String) -> String? {
        guard let start = source.range(of: signature),
              let open = source[start.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        var inString = false
        while index < source.endIndex {
            let character = source[index]
            let next = source.index(after: index)
            if inString {
                if character == "\\", next < source.endIndex {
                    index = source.index(after: next)
                    continue
                }
                if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "/", next < source.endIndex, source[next] == "/" {
                while index < source.endIndex, source[index] != "\n" { index = source.index(after: index) }
                continue
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return String(source[source.index(after: open)..<index]) }
            }
            index = next
        }
        return nil
    }

    /// The slice of `text` from `start` up to (not including) `end`.
    static func slice(of text: String, from start: String, to end: String) -> String? {
        guard let lower = text.range(of: start),
              let upper = text.range(of: end, range: lower.upperBound..<text.endIndex) else { return nil }
        return String(text[lower.lowerBound..<upper.lowerBound])
    }
}
