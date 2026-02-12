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

private func isSelectNextCandidatePage(_ action: ClientAction) -> Bool {
    if case .selectNextCandidatePage = action {
        return true
    }
    return false
}

private func isSelectPrevCandidatePage(_ action: ClientAction) -> Bool {
    if case .selectPrevCandidatePage = action {
        return true
    }
    return false
}

private func isSelectFirstCandidate(_ action: ClientAction) -> Bool {
    if case .selectFirstCandidate = action {
        return true
    }
    return false
}

private func isSelectLastCandidate(_ action: ClientAction) -> Bool {
    if case .selectLastCandidate = action {
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

@Test func selectingStateMapsPageNavigationToPageActions() async throws {
    let state: InputState = .selecting
    let pageDownResult = state.event(
        eventCore: makeEvent(),
        userAction: .navigation(.pageDown),
        inputLanguage: .japanese,
        liveConversionEnabled: true,
        enableDebugWindow: false,
        enableSuggestion: false
    )
    let pageUpResult = state.event(
        eventCore: makeEvent(),
        userAction: .navigation(.pageUp),
        inputLanguage: .japanese,
        liveConversionEnabled: true,
        enableDebugWindow: false,
        enableSuggestion: false
    )

    #expect(isSelectNextCandidatePage(pageDownResult.0))
    #expect(isFallthrough(pageDownResult.1))
    #expect(isSelectPrevCandidatePage(pageUpResult.0))
    #expect(isFallthrough(pageUpResult.1))
}

@Test func selectingStateMapsHomeEndNavigationToBoundaryActions() async throws {
    let state: InputState = .selecting
    let homeResult = state.event(
        eventCore: makeEvent(),
        userAction: .navigation(.home),
        inputLanguage: .japanese,
        liveConversionEnabled: true,
        enableDebugWindow: false,
        enableSuggestion: false
    )
    let endResult = state.event(
        eventCore: makeEvent(),
        userAction: .navigation(.end),
        inputLanguage: .japanese,
        liveConversionEnabled: true,
        enableDebugWindow: false,
        enableSuggestion: false
    )

    #expect(isSelectFirstCandidate(homeResult.0))
    #expect(isFallthrough(homeResult.1))
    #expect(isSelectLastCandidate(endResult.0))
    #expect(isFallthrough(endResult.1))
}
