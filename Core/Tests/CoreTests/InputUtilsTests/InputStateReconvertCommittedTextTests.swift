import Core
import KanaKanjiConverterModule
import Testing

private func makeEvent(modifiers: KeyEventCore.ModifierFlag = []) -> KeyEventCore {
    KeyEventCore(
        modifierFlags: modifiers,
        characters: nil,
        charactersIgnoringModifiers: nil,
        keyCode: 0
    )
}

private func isReconvertCommittedText(_ action: ClientAction) -> Bool {
    if case .reconvertCommittedText = action {
        return true
    }
    return false
}

private func isFallthrough(_ callback: ClientActionCallback) -> Bool {
    if case .fallthrough = callback {
        return true
    }
    return false
}

@Test func reconvertActionIsAcceptedFromPrimaryStates() async throws {
    let states: [InputState] = [
        .none,
        .composing,
        .previewing,
        .selecting,
        .replaceSuggestion
    ]

    for state in states {
        let result = state.event(
            eventCore: makeEvent(),
            userAction: .reconvertCommittedText,
            inputLanguage: .japanese,
            liveConversionEnabled: true,
            enableDebugWindow: false,
            enableSuggestion: false
        )
        #expect(isReconvertCommittedText(result.0))
        #expect(isFallthrough(result.1))
    }
}
