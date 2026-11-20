import Foundation

enum JapaneseRomanizer {
    private static let jaLocale = Locale(identifier: "ja") as CFLocale

    static func containsKana(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x3040...0x309F).contains(v) || (0x30A0...0x30FF).contains(v) {
                return true
            }
        }
        return false
    }

    static func containsJapaneseOrCJK(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x3040...0x309F).contains(v)
                || (0x30A0...0x30FF).contains(v)
                || (0x4E00...0x9FFF).contains(v)
                || (0x3400...0x4DBF).contains(v) {
                return true
            }
        }
        return false
    }

    static func isJapaneseTrack(_ lines: [LyricLine]) -> Bool {
        lines.contains { containsKana($0.text) }
    }

    static func romanizeLine(_ text: String) -> String {
        guard containsJapaneseOrCJK(text) else { return text }

        let nsText = text as NSString
        let cfText = text as CFString
        let fullRange = CFRange(location: 0, length: CFStringGetLength(cfText))

        guard let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            cfText,
            fullRange,
            kCFStringTokenizerUnitWord,
            jaLocale
        ) else {
            return text
        }

        var parts: [String] = []
        var cursor = 0

        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let tokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            guard tokenRange.location != kCFNotFound, tokenRange.length > 0 else { continue }

            // Preserve any gap (punctuation/spaces) between tokens
            if tokenRange.location > cursor {
                let gap = nsText.substring(with: NSRange(location: cursor, length: tokenRange.location - cursor))
                    .trimmingCharacters(in: .whitespaces)
                if !gap.isEmpty {
                    let normalizedGap = gap
                        .replacingOccurrences(of: "、", with: ", ")
                        .replacingOccurrences(of: "。", with: ".")
                        .replacingOccurrences(of: "！", with: "!")
                        .replacingOccurrences(of: "？", with: "?")
                        .replacingOccurrences(of: "「", with: "\"")
                        .replacingOccurrences(of: "」", with: "\"")
                    parts.append(normalizedGap)
                }
            }

            let rawToken = nsText.substring(with: NSRange(location: tokenRange.location, length: tokenRange.length))
            if containsJapaneseOrCJK(rawToken),
               let latin = CFStringTokenizerCopyCurrentTokenAttribute(
                   tokenizer,
                   kCFStringTokenizerAttributeLatinTranscription
               ) as? String,
               !latin.isEmpty {
                // Convert macOS macrons (ō, ū, etc.) to clean readable romaji and normalize particle "ha"
                let cleaned = latin
                    .replacingOccurrences(of: "ō", with: "ou")
                    .replacingOccurrences(of: "ū", with: "uu")
                    .replacingOccurrences(of: "ā", with: "aa")
                    .replacingOccurrences(of: "ī", with: "ii")
                    .replacingOccurrences(of: "ē", with: "ee")
                if rawToken == "は" && cleaned == "ha" {
                    parts.append("wa")
                } else {
                    parts.append(cleaned)
                }
            } else {
                parts.append(rawToken)
            }

            cursor = tokenRange.location + tokenRange.length
        }

        if cursor < nsText.length {
            let tail = nsText.substring(from: cursor).trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty {
                parts.append(tail)
            }
        }

        let joined = parts.joined(separator: " ")
            .replacingOccurrences(of: " ,", with: ",")
            .replacingOccurrences(of: " .", with: ".")
            .replacingOccurrences(of: " !", with: "!")
            .replacingOccurrences(of: " ?", with: "?")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return joined.isEmpty ? text : joined
    }
}
