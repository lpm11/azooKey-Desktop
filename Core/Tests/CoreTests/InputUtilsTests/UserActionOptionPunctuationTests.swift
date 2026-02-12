import Core
import Foundation
import KanaKanjiConverterModule
import Testing

private let punctuationStyleTestLock = NSLock()

private func inputPiecesToString(_ inputPieces: [InputPiece]) -> String {
    String(inputPieces.compactMap {
        switch $0 {
        case .character(let c): c
        case .key(intention: let cint, input: let cinp, modifiers: _): cint ?? cinp
        case .compositionSeparator: nil
        }
    })
}


private func inputString(from action: UserAction) -> String? {
    guard case .input(let pieces) = action else {
        return nil
    }
    return pieces.inputString(preferIntention: true)
}

private func makeEvent(
    logicalKey: String,
    characters: String?,
    modifiers: KeyEventCore.ModifierFlag
) -> KeyEventCore {
    KeyEventCore(
        modifierFlags: modifiers,
        characters: characters,
        charactersIgnoringModifiers: logicalKey,
        keyCode: 0
    )
}

private func makePhysicalKeyEvent(keyCode: UInt16) -> KeyEventCore {
    KeyEventCore(
        modifierFlags: [],
        characters: nil,
        charactersIgnoringModifiers: nil,
        keyCode: keyCode
    )
}

@Test func testOptionPunctuationMappings() throws {
    punctuationStyleTestLock.lock()
    defer { punctuationStyleTestLock.unlock() }

    let defaults = UserDefaults.standard
    let key = Config.PunctuationStyle.key
    let originalData = defaults.data(forKey: key)
    defer {
        if let data = originalData {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    let option: KeyEventCore.ModifierFlag = [.option]
    let shiftOption: KeyEventCore.ModifierFlag = [.shift, .option]

    Config.PunctuationStyle().value = .kutenAndToten
    #expect(inputString(from: UserAction.getUserAction(
        eventCore: makeEvent(logicalKey: ",", characters: "≤", modifiers: option),
        inputLanguage: .japanese
    )) == "，")
    #expect(inputString(from: UserAction.getUserAction(
        eventCore: makeEvent(logicalKey: ".", characters: "≥", modifiers: option),
        inputLanguage: .japanese
    )) == "．")

    Config.PunctuationStyle().value = .periodAndComma
    #expect(inputString(from: UserAction.getUserAction(
        eventCore: makeEvent(logicalKey: ",", characters: "≤", modifiers: option),
        inputLanguage: .japanese
    )) == "、")
    #expect(inputString(from: UserAction.getUserAction(
        eventCore: makeEvent(logicalKey: ".", characters: "≥", modifiers: option),
        inputLanguage: .japanese
    )) == "。")

    #expect(inputString(from: UserAction.getUserAction(
        eventCore: makeEvent(logicalKey: "[", characters: "[", modifiers: option),
        inputLanguage: .japanese
    )) == "［")
    #expect(inputString(from: UserAction.getUserAction(
        eventCore: makeEvent(logicalKey: "[", characters: "{", modifiers: shiftOption),
        inputLanguage: .japanese
    )) == "｛")
    #expect(inputString(from: UserAction.getUserAction(
        eventCore: makeEvent(logicalKey: "]", characters: "]", modifiers: option),
        inputLanguage: .japanese
    )) == "］")
    #expect(inputString(from: UserAction.getUserAction(
        eventCore: makeEvent(logicalKey: "]", characters: "}", modifiers: shiftOption),
        inputLanguage: .japanese
    )) == "｝")
    #expect(inputString(from: UserAction.getUserAction(
        eventCore: makeEvent(logicalKey: ",", characters: "¯", modifiers: shiftOption),
        inputLanguage: .japanese
    )) == "¯")
    #expect(inputString(from: UserAction.getUserAction(
        eventCore: makeEvent(logicalKey: ".", characters: "˘", modifiers: shiftOption),
        inputLanguage: .japanese
    )) == "˘")
}

@Test func testPreserveASCIISymbolKeysForCustomTable() throws {
    punctuationStyleTestLock.lock()
    defer { punctuationStyleTestLock.unlock() }

    let defaults = UserDefaults.standard
    let key = Config.PunctuationStyle.key
    let originalData = defaults.data(forKey: key)
    defer {
        if let data = originalData {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    Config.PunctuationStyle().value = .kutenAndToten

    #expect(inputString(from: UserAction.getUserAction(
        eventCore: makeEvent(logicalKey: ".", characters: ".", modifiers: []),
        inputLanguage: .japanese
    )) == "。")
    #expect(inputString(from: UserAction.getUserAction(
        eventCore: makeEvent(logicalKey: ".", characters: ".", modifiers: []),
        inputLanguage: .japanese,
        preserveASCIISymbolKeys: true
    )) == ".")

    #expect(inputString(from: UserAction.getUserAction(
        eventCore: makeEvent(logicalKey: ",", characters: ",", modifiers: []),
        inputLanguage: .japanese,
        preserveASCIISymbolKeys: true
    )) == ",")
    #expect(inputString(from: UserAction.getUserAction(
        eventCore: makeEvent(logicalKey: ";", characters: ";", modifiers: []),
        inputLanguage: .japanese,
        preserveASCIISymbolKeys: true
    )) == ";")
    #expect(inputString(from: UserAction.getUserAction(
        eventCore: makeEvent(logicalKey: "\"", characters: "\"", modifiers: []),
        inputLanguage: .japanese,
        preserveASCIISymbolKeys: true
    )) == "\"")
}

@Test func testPageNavigationKeyMappings() throws {
    let pageUpAction = UserAction.getUserAction(
        eventCore: makePhysicalKeyEvent(keyCode: 0x74),
        inputLanguage: .japanese
    )
    let pageDownAction = UserAction.getUserAction(
        eventCore: makePhysicalKeyEvent(keyCode: 0x79),
        inputLanguage: .japanese
    )

    #expect({
        if case .navigation(.pageUp) = pageUpAction {
            return true
        }
        return false
    }())
    #expect({
        if case .navigation(.pageDown) = pageDownAction {
            return true
        }
        return false
    }())
    let homeAction = UserAction.getUserAction(
        eventCore: makePhysicalKeyEvent(keyCode: 0x73),
        inputLanguage: .japanese
    )
    let endAction = UserAction.getUserAction(
        eventCore: makePhysicalKeyEvent(keyCode: 0x77),
        inputLanguage: .japanese
    )

    #expect({
        if case .navigation(.home) = homeAction {
            return true
        }
        return false
    }())
    #expect({
        if case .navigation(.end) = endAction {
            return true
        }
        return false
    }())
}
