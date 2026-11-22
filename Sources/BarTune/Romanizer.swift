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
        let joined = finish(romanizedParts(text).map(\.text).joined(separator: " "))
        return joined.isEmpty ? text : joined
    }

    struct RomanizedWordSpan: Equatable {
        let text: String
        let sourceRange: ClosedRange<Int>
    }

    /// Romanizes the words of one timed line in context, so readings and small っ that span word
    /// boundaries come out as they do for the whole line. Returns one string per word; a word whose
    /// reading was merged into the previous word gets "".
    static func romanizeWords(_ words: [String]) -> [String] {
        let text = words.joined()
        guard containsJapaneseOrCJK(text) else { return words }
        var out = Array(repeating: "", count: words.count)
        for span in romanizeWordSpans(words) {
            out[span.sourceRange.lowerBound] = span.text
        }
        return out
    }

    /// Romanizes timed words in context and returns each non-empty romanized span along with the
    /// inclusive range of source word indices that contributed to it.
    static func romanizeWordSpans(_ words: [String]) -> [RomanizedWordSpan] {
        guard !words.isEmpty else { return [] }
        let text = words.joined()
        guard containsJapaneseOrCJK(text) else {
            return words.enumerated().map { RomanizedWordSpan(text: $0.element, sourceRange: $0.offset...$0.offset) }
        }
        var wordStarts: [Int] = []
        var location = 0
        for word in words {
            wordStarts.append(location)
            location += (word as NSString).length
        }
        var grouped = Array(repeating: [String](), count: words.count)
        var endIndices = Array(0..<words.count)
        for part in romanizedParts(text) {
            let owner = wordStarts.lastIndex { $0 <= part.location } ?? 0
            let lastWord = wordStarts.lastIndex { $0 < part.end } ?? owner
            grouped[owner].append(part.text)
            if lastWord > endIndices[owner] {
                endIndices[owner] = lastWord
            }
        }
        return grouped.enumerated().compactMap { index, parts in
            let finished = finish(parts.joined(separator: " "))
            guard !finished.isEmpty else { return nil }
            return RomanizedWordSpan(text: finished, sourceRange: index...endIndices[index])
        }
    }

    private static func finish(_ joined: String) -> String {
        resolveSokuon(
            joined
                .replacingOccurrences(of: "~tsu ", with: "~tsu")
                .replacingOccurrences(of: " ,", with: ",")
                .replacingOccurrences(of: " .", with: ".")
                .replacingOccurrences(of: " !", with: "!")
                .replacingOccurrences(of: " ?", with: "?")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Romanized tokens and punctuation of `text`, each with its UTF-16 range. A token ending in a
    /// small っ is merged with the token after it, which supplies the doubled consonant.
    private static func romanizedParts(_ text: String) -> [(location: Int, end: Int, text: String)] {
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
            return [(0, nsText.length, text)]
        }

        var parts: [(location: Int, end: Int, text: String)] = []
        var cursor = 0

        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
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
                    parts.append((cursor, tokenRange.location, normalizedGap))
                }
            }

            let tokenEnd = tokenRange.location + tokenRange.length
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
                    parts.append((tokenRange.location, tokenEnd, "wa"))
                } else {
                    parts.append((tokenRange.location, tokenEnd, cleaned))
                }
            } else {
                parts.append((tokenRange.location, tokenEnd, rawToken))
            }

            cursor = tokenEnd
        }

        if cursor < nsText.length {
            let tail = nsText.substring(from: cursor).trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty {
                parts.append((cursor, nsText.length, tail))
            }
        }

        var merged: [(location: Int, end: Int, text: String)] = []
        for part in parts {
            if let last = merged.last, last.text.hasSuffix("~tsu") {
                merged[merged.count - 1].text = last.text + part.text
                merged[merged.count - 1].end = max(last.end, part.end)
            } else {
                merged.append(part)
            }
        }
        return merged
    }

    /// Converts macOS tokenizer's `~tsu` (small っ) into a doubled following consonant (e.g., `waka~tsuteru` -> `wakatteru`).
    private static func resolveSokuon(_ input: String) -> String {
        guard input.contains("~tsu") else { return input }
        let chars = Array(input)
        var out = ""
        var i = 0
        while i < chars.count {
            if i + 3 < chars.count,
               chars[i] == "~", chars[i + 1] == "t", chars[i + 2] == "s", chars[i + 3] == "u" {
                if i + 4 < chars.count, chars[i + 4].isLetter {
                    out.append(chars[i + 4])
                }
                i += 4
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }
}

enum KoreanRomanizer {
    private static let initials = [
        "g", "kk", "n", "d", "tt", "r", "m", "b", "pp", "s",
        "ss", "", "j", "jj", "ch", "k", "t", "p", "h",
    ]
    private static let medials = [
        "a", "ae", "ya", "yae", "eo", "e", "yeo", "ye", "o", "wa",
        "wae", "oe", "yo", "u", "wo", "we", "wi", "yu", "eu", "ui", "i",
    ]
    private static let finals = [
        "", "k", "k", "k", "n", "n", "n", "t", "l", "k",
        "m", "l", "l", "l", "l", "l", "m", "p", "p", "t",
        "t", "ng", "t", "t", "k", "t", "p", "t",
    ]

    static func containsHangul(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0xAC00...0xD7A3).contains(v)
                || (0x1100...0x11FF).contains(v)
                || (0x3130...0x318F).contains(v) {
                return true
            }
        }
        return false
    }

    static func isKoreanTrack(_ lines: [LyricLine]) -> Bool {
        lines.contains { containsHangul($0.text) }
    }

    static func romanizeLine(_ text: String) -> String {
        guard containsHangul(text) else { return text }

        var out = ""
        out.reserveCapacity(text.count * 2)

        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v >= 0xAC00 && v <= 0xD7A3 {
                let index = Int(v - 0xAC00)
                let initial = index / (21 * 28)
                let medial = (index % (21 * 28)) / 28
                let final = index % 28
                out.append(initials[initial])
                out.append(medials[medial])
                out.append(finals[final])
            } else {
                out.unicodeScalars.append(scalar)
            }
        }

        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? text : trimmed
    }
}

enum ChineseRomanizer {
    static func containsHan(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) {
                return true
            }
        }
        return false
    }

    static func isChineseTrack(_ lines: [LyricLine]) -> Bool {
        guard !JapaneseRomanizer.isJapaneseTrack(lines),
              !KoreanRomanizer.isKoreanTrack(lines)
        else { return false }
        return lines.contains { containsHan($0.text) }
    }

    static func romanizeLine(_ text: String) -> String {
        guard containsHan(text) else { return text }
        guard let pinyin = text.applyingTransform(.mandarinToLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false)
        else { return text }

        let cleaned = pinyin
            .replacingOccurrences(of: "，", with: ", ")
            .replacingOccurrences(of: "。", with: ".")
            .replacingOccurrences(of: "！", with: "!")
            .replacingOccurrences(of: "？", with: "?")
            .replacingOccurrences(of: " ,", with: ",")
            .replacingOccurrences(of: " .", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? text : cleaned
    }
}
