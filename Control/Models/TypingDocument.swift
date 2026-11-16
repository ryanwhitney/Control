import Foundation

/// The phone's copy of what's been typed into the Mac in this burst. The
/// keyboard needs text to work against — composing input (pinyin, kana,
/// Hangul) and the space-bar trackpad both read and edit it — but the Mac's
/// field can't be read, so this holds only what was typed here. Every change
/// returns the `TypingEdit`s that make the same change on the Mac.
///
/// Offsets are UTF-16, as `NSRange` and UIKit's text input use. Text being
/// composed (marked) stays on the phone until the keyboard commits it, so the
/// Mac's caret is tracked in *committed* text: everything but the marked range.
struct TypingDocument {
    private(set) var text = ""
    private(set) var selection = NSRange(location: 0, length: 0)
    private(set) var markedRange: NSRange?
    /// Where the Mac's caret is, in committed text. Moved lazily: a ranged
    /// selection isn't mirrored, and the edit that replaces it moves the caret.
    private var macCaret = 0

    /// Well past any burst; trimmed so a long session doesn't grow without end.
    private static let maxLength = 4000

    var length: Int { text.utf16.count }

    var markedText: String {
        markedRange.map { substring($0) } ?? ""
    }

    func substring(_ range: NSRange) -> String {
        (text as NSString).substring(with: clamped(range))
    }

    // MARK: Edits

    mutating func insert(_ string: String) -> [TypingEdit] {
        guard let marked = markedRange else {
            return replace(selection, with: string)
        }
        // Commits the composition as `string`; none of it is on the Mac yet.
        var edits = moveMac(to: marked.location)
        text = (text as NSString).replacingCharacters(in: marked, with: string)
        markedRange = nil
        if !string.isEmpty { edits.append(.text(string)) }
        caret(at: marked.location + string.utf16.count)
        trimIfNeeded()
        return edits
    }

    mutating func replace(_ range: NSRange, with string: String) -> [TypingEdit] {
        if let marked = markedRange, NSEqualRanges(range, marked) {
            return insert(string)
        }
        var edits = commitMarked()
        let range = clamped(range)
        edits += moveMac(to: NSMaxRange(range))
        let removed = characterCount(in: text, from: range.location, to: NSMaxRange(range))
        if removed > 0 { edits.append(.deleteBackward(removed)) }
        text = (text as NSString).replacingCharacters(in: range, with: string)
        if !string.isEmpty { edits.append(.text(string)) }
        caret(at: range.location + string.utf16.count)
        trimIfNeeded()
        return edits
    }

    mutating func deleteBackward() -> [TypingEdit] {
        if let marked = markedRange {
            // Keyboards revise a composition through `setMarked`; this covers
            // one that deletes instead. Local, like the composition itself.
            guard marked.length > 0 else { markedRange = nil; return [] }
            let last = (text as NSString).rangeOfComposedCharacterSequence(at: NSMaxRange(marked) - 1)
            text = (text as NSString).replacingCharacters(in: last, with: "")
            let remaining = marked.length - last.length
            markedRange = remaining > 0 ? NSRange(location: marked.location, length: remaining) : nil
            selection = NSRange(location: marked.location + remaining, length: 0)
            return []
        }
        if selection.length > 0 {
            return replace(selection, with: "")
        }
        guard selection.location > 0 else {
            // Before anything typed here: the Mac has text the phone can't see.
            var edits = moveMac(to: 0)
            edits.append(.deleteBackward(1))
            return edits
        }
        let previous = (text as NSString).rangeOfComposedCharacterSequence(at: selection.location - 1)
        return replace(NSRange(location: previous.location, length: selection.location - previous.location), with: "")
    }

    /// Composing stays local; only a selection it types over is deleted on the
    /// Mac now, since that's already decided.
    mutating func setMarked(_ string: String, selectedRange: NSRange) -> [TypingEdit] {
        var edits: [TypingEdit] = []
        let target: NSRange
        if let marked = markedRange {
            target = marked
        } else {
            if selection.length > 0 {
                edits = replace(selection, with: "")
            }
            target = NSRange(location: selection.location, length: 0)
        }
        text = (text as NSString).replacingCharacters(in: target, with: string)
        let markedLength = string.utf16.count
        markedRange = markedLength > 0 ? NSRange(location: target.location, length: markedLength) : nil
        let start = min(max(0, selectedRange.location), markedLength)
        let end = min(start + max(0, selectedRange.length), markedLength)
        selection = NSRange(location: target.location + start, length: end - start)
        return edits
    }

    mutating func commitMarked() -> [TypingEdit] {
        guard let marked = markedRange else { return [] }
        let composed = substring(marked)
        var edits = moveMac(to: marked.location)
        markedRange = nil
        if !composed.isEmpty { edits.append(.text(composed)) }
        macCaret = NSMaxRange(marked)
        return edits
    }

    mutating func select(_ range: NSRange) -> [TypingEdit] {
        selection = clamped(range)
        guard markedRange == nil, selection.length == 0 else { return [] }
        return moveMac(to: selection.location)
    }

    // MARK: Characters

    /// Grapheme count before `offset`: what the trackpad and caret geometry
    /// step through, one per visible character.
    func characterIndex(of offset: Int) -> Int {
        characterCount(in: text, from: 0, to: offset)
    }

    /// The UTF-16 offset before character `index`, clamped to the text.
    func offset(ofCharacterIndex index: Int) -> Int {
        guard index > 0 else { return 0 }
        var offset = 0
        for character in text.prefix(index) {
            offset += character.utf16.count
        }
        return offset
    }

    // MARK: Private

    /// Arrow presses step by character, as they do on the Mac.
    private mutating func moveMac(to target: Int) -> [TypingEdit] {
        let committed = committedText
        let steps = characterCount(in: committed, from: macCaret, to: target)
        let edit: TypingEdit? = steps == 0 ? nil : (target > macCaret ? .moveRight(steps) : .moveLeft(steps))
        macCaret = target
        return edit.map { [$0] } ?? []
    }

    private var committedText: String {
        guard let marked = markedRange else { return text }
        return (text as NSString).replacingCharacters(in: marked, with: "")
    }

    private mutating func caret(at offset: Int) {
        selection = NSRange(location: offset, length: 0)
        macCaret = offset
    }

    private func clamped(_ range: NSRange) -> NSRange {
        let start = min(max(0, range.location), length)
        let end = min(max(start, NSMaxRange(range)), length)
        return NSRange(location: start, length: end - start)
    }

    private func characterCount(in string: String, from a: Int, to b: Int) -> Int {
        let utf16 = string.utf16
        let lowOffset = min(max(0, min(a, b)), utf16.count)
        let highOffset = min(max(0, max(a, b)), utf16.count)
        let low = utf16.index(utf16.startIndex, offsetBy: lowOffset)
        let high = utf16.index(utf16.startIndex, offsetBy: highOffset)
        return string[low..<high].count
    }

    /// Drops the oldest half once the text is long, keeping offsets aligned.
    /// Skipped while composing or with the caret back in the dropped part.
    private mutating func trimIfNeeded() {
        guard length > Self.maxLength, markedRange == nil else { return }
        let cut = (text as NSString).rangeOfComposedCharacterSequence(at: length / 2).location
        guard cut > 0, selection.location >= cut, macCaret >= cut else { return }
        text = (text as NSString).substring(from: cut)
        selection.location -= cut
        macCaret -= cut
    }
}
