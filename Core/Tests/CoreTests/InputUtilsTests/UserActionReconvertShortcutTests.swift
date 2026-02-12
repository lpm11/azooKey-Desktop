import Core
import KanaKanjiConverterModule
import Testing

private func makeControlShiftEvent(
    logicalKey: String,
    characters: String?
) -> KeyEventCore {
    KeyEventCore(
        modifierFlags: [.control, .shift],
        characters: characters,
        charactersIgnoringModifiers: logicalKey,
        keyCode: 0
    )
}

private func isReconvertCommittedTextAction(_ action: UserAction) -> Bool {
    if case .reconvertCommittedText = action {
        return true
    }
    return false
}

@Test func controlShiftRMapsToReconvertCommittedTextAction() throws {
    let action = UserAction.getUserAction(
        eventCore: makeControlShiftEvent(logicalKey: "r", characters: "R"),
        inputLanguage: .japanese
    )

    #expect(isReconvertCommittedTextAction(action))
}
