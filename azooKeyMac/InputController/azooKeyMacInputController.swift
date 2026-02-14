import Cocoa
import Core
import InputMethodKit
import KanaKanjiConverterModuleWithDefaultDictionary

@objc(azooKeyMacInputController)
class azooKeyMacInputController: IMKInputController, NSMenuItemValidation { // swiftlint:disable:this type_name
    var segmentsManager: SegmentsManager
    private(set) var inputState: InputState = .none
    private var inputLanguage: InputLanguage = .japanese
    var liveConversionEnabled: Bool {
        Config.LiveConversion().value
    }

    var appMenu: NSMenu
    var liveConversionToggleMenuItem: NSMenuItem
    var transformSelectedTextMenuItem: NSMenuItem
    var pseudoRestartMenuItem: NSMenuItem

    private var candidatesWindow: NSWindow
    private var candidatesViewController: CandidatesViewController

    private var predictionWindow: NSWindow
    private var predictionViewController: PredictionCandidatesViewController
    private var lastPredictionCandidates: [SegmentsManager.PredictionCandidate] = []
    private var predictionSelectionIndex: Int?
    private var lastPredictionUpdateTime: TimeInterval = 0
    private var predictionHideWorkItem: DispatchWorkItem?

    private var replaceSuggestionWindow: NSWindow
    private var replaceSuggestionsViewController: ReplaceSuggestionsViewController
    private var replaceSuggestionTask: Task<Void, Never>?
    private var promptPreviewTask: Task<Void, Never>?
    private var restartEpoch: UInt64 = 0

    var promptInputWindow: PromptInputWindow
    var isPromptWindowVisible: Bool = false

    // ダブルタップ検出用
    private var lastKey: (time: TimeInterval, code: UInt16) = (0, 0)
    private struct LastCommittedEntry {
        let text: String
        let reading: String
    }
    private var lastCommittedEntry: LastCommittedEntry?
    private var markedTextReplacementRange: NSRange?
    private static let reconvertReadingLocale: CFLocale = {
        let identifier = CFLocaleCreateCanonicalLanguageIdentifierFromString(kCFAllocatorDefault, "ja" as CFString)
        return CFLocaleCreate(kCFAllocatorDefault, identifier)
    }()
    private static let doubleTapInterval: TimeInterval = 0.5
    private static let candidateWindowInitialSize = CGSize(width: 400, height: 1000)

    private static func makeCandidateWindow(contentViewController: NSViewController, inputClient: IMKTextInput?) -> NSWindow {
        let window = NSWindow(contentViewController: contentViewController)
        window.styleMask = [.borderless]
        window.level = .popUpMenu

        var rect: NSRect = .zero
        inputClient?.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        rect.size = candidateWindowInitialSize
        window.setFrame(rect, display: true)
        window.setIsVisible(false)
        window.orderOut(nil)
        return window
    }

    // MARK: - ダブルタップ検出
    private func checkAndUpdateDoubleTap(keyCode: UInt16) -> Bool {
        let now = Date().timeIntervalSince1970
        let isDouble = (self.lastKey.code == keyCode) && (now - self.lastKey.time < Self.doubleTapInterval)
        self.lastKey = (time: now, code: keyCode)
        return isDouble
    }

    private func reading(from candidate: Candidate) -> String {
        candidate.data.map(\.ruby).joined()
    }

    private static func estimatedHiraganaReadingForNonASCII(_ text: String) -> String {
        guard !text.isEmpty else {
            return text
        }

        let nsText = text as NSString
        let options = kCFStringTokenizerUnitWordBoundary | kCFStringTokenizerAttributeLatinTranscription
        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            text as CFString,
            CFRangeMake(0, nsText.length),
            options,
            Self.reconvertReadingLocale
        )

        var tokenType = CFStringTokenizerGoToTokenAtIndex(tokenizer, 0)
        var output = ""
        while tokenType != [] {
            let tokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let nsRange = NSRange(location: tokenRange.location, length: tokenRange.length)
            let token = nsText.substring(with: nsRange)
            let onlyNonLetterToken = token.unicodeScalars.allSatisfy {
                CharacterSet.punctuationCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
            }
            if onlyNonLetterToken {
                output += token
            } else if
                let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String,
                let hiragana = latin.applyingTransform(.latinToHiragana, reverse: false) {
                output += hiragana
            } else {
                output += token
            }
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }

        return output.isEmpty ? text : output
    }

    // 選択範囲再変換向けに、表示文字列から再投入用のひらがな読みを推定する。
    // ASCII 連続区間はそのまま保持し、非 ASCII 連続区間だけ tokenizer で推定する。
    static func estimatedHiraganaReadingForReconvert(_ text: String) -> String {
        guard !text.isEmpty else {
            return text
        }

        var output = ""
        var current = ""
        var currentIsASCII: Bool?

        func flushCurrentChunk() {
            guard !current.isEmpty, let isASCII = currentIsASCII else {
                return
            }
            if isASCII {
                output += current
            } else {
                output += Self.estimatedHiraganaReadingForNonASCII(current)
            }
            current = ""
            currentIsASCII = nil
        }

        for scalar in text.unicodeScalars {
            let isASCII = scalar.isASCII
            if currentIsASCII == nil || currentIsASCII == isASCII {
                current.unicodeScalars.append(scalar)
                currentIsASCII = isASCII
            } else {
                flushCurrentChunk()
                current.unicodeScalars.append(scalar)
                currentIsASCII = isASCII
            }
        }
        flushCurrentChunk()

        return output
    }

    @MainActor
    private func recordLastCommittedText(text: String, reading: String? = nil) {
        guard !text.isEmpty else {
            return
        }
        let normalizedReading = if let reading, !reading.isEmpty {
            reading
        } else {
            text
        }
        self.lastCommittedEntry = .init(text: text, reading: normalizedReading)
    }

    @MainActor
    private func reconvertCommittedText(client: IMKTextInput) -> Bool {
        let selectedRange = client.selectedRange()
        if selectedRange.length > 0 {
            return self.reconvertSelectedText(client: client, selectedRange: selectedRange)
        }
        return self.reconvertLastCommittedText(client: client, cursorRange: selectedRange)
    }

    @MainActor
    private func reconvertSelectedText(client: IMKTextInput, selectedRange: NSRange) -> Bool {
        var actualRange = NSRange()
        guard let selectedText = client.string(from: selectedRange, actualRange: &actualRange), !selectedText.isEmpty else {
            self.segmentsManager.appendDebugMessage("Reconvert ignored: failed to fetch selected text")
            return false
        }
        let selectedReading = Self.estimatedHiraganaReadingForReconvert(selectedText)
        if selectedReading != selectedText {
            self.segmentsManager.appendDebugMessage("Reconvert selected text: estimated reading '\(selectedReading)'")
        }

        if !self.segmentsManager.isEmpty {
            self.segmentsManager.stopComposition()
        }
        self.markedTextReplacementRange = selectedRange
        self.segmentsManager.insertAtCursorPosition(selectedReading, inputStyle: self.inputStyle)
        self.inputState = .composing
        self.replaceSuggestionWindow.orderOut(nil)
        return true
    }

    @MainActor
    private func reconvertLastCommittedText(client: IMKTextInput, cursorRange: NSRange) -> Bool {
        guard let lastCommittedEntry else {
            self.segmentsManager.appendDebugMessage("Reconvert ignored: no last committed entry")
            return false
        }
        guard cursorRange.location != NSNotFound else {
            self.segmentsManager.appendDebugMessage("Reconvert ignored: cursor location is not found")
            return false
        }

        let committedLength = (lastCommittedEntry.text as NSString).length
        guard committedLength > 0, cursorRange.location >= committedLength else {
            self.segmentsManager.appendDebugMessage("Reconvert ignored: cursor is not after last committed text")
            return false
        }

        let targetRange = NSRange(location: cursorRange.location - committedLength, length: committedLength)
        var actualRange = NSRange()
        guard let textBeforeCursor = client.string(from: targetRange, actualRange: &actualRange) else {
            self.segmentsManager.appendDebugMessage("Reconvert ignored: failed to read text before cursor")
            return false
        }
        guard actualRange.location == targetRange.location, actualRange.length == targetRange.length else {
            self.segmentsManager.appendDebugMessage("Reconvert ignored: actual range mismatch")
            return false
        }
        guard textBeforeCursor == lastCommittedEntry.text else {
            self.segmentsManager.appendDebugMessage("Reconvert ignored: text before cursor does not match last commit")
            return false
        }

        if !self.segmentsManager.isEmpty {
            self.segmentsManager.stopComposition()
        }
        self.markedTextReplacementRange = targetRange
        self.segmentsManager.insertAtCursorPosition(lastCommittedEntry.reading, inputStyle: self.inputStyle)
        self.inputState = .composing
        self.replaceSuggestionWindow.orderOut(nil)
        return true
    }

    static func predictionSelectionIndex(
        current: Int?,
        direction: UserAction.NavigationDirection,
        candidateCount: Int
    ) -> Int? {
        guard candidateCount > 0 else {
            return nil
        }
        switch direction {
        case .down:
            if let current {
                return (current + 1) % candidateCount
            } else {
                return 0
            }
        case .up:
            if let current {
                return (current - 1 + candidateCount) % candidateCount
            } else {
                return candidateCount - 1
            }
        case .left, .right, .pageUp, .pageDown, .home, .end:
            return current
        }
    }

    static func shouldApplyAsyncResult(taskEpoch: UInt64, currentEpoch: UInt64) -> Bool {
        taskEpoch == currentEpoch
    }

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        let applicationDirectoryURL = if #available(macOS 13, *) {
            URL.applicationSupportDirectory
            .appending(path: "azooKey", directoryHint: .isDirectory)
            .appending(path: "memory", directoryHint: .isDirectory)
        } else {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("azooKey", isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        }

        let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.dev.lpm11.inputmethod.azooKeyMac")
        self.segmentsManager = SegmentsManager(
            kanaKanjiConverter: (NSApplication.shared.delegate as? AppDelegate)!.kanaKanjiConverter,
            applicationDirectoryURL: applicationDirectoryURL,
            containerURL: containerURL
        )

        self.appMenu = NSMenu(title: "azooKey")
        self.liveConversionToggleMenuItem = NSMenuItem()
        self.transformSelectedTextMenuItem = NSMenuItem()
        self.pseudoRestartMenuItem = NSMenuItem()

        let textInputClient = inputClient as? IMKTextInput

        let candidatesViewController = CandidatesViewController()
        let predictionViewController = PredictionCandidatesViewController()
        let replaceSuggestionsViewController = ReplaceSuggestionsViewController()

        self.candidatesViewController = candidatesViewController
        self.predictionViewController = predictionViewController
        self.replaceSuggestionsViewController = replaceSuggestionsViewController

        self.candidatesWindow = Self.makeCandidateWindow(
            contentViewController: candidatesViewController,
            inputClient: textInputClient
        )
        self.predictionWindow = Self.makeCandidateWindow(
            contentViewController: predictionViewController,
            inputClient: textInputClient
        )
        self.replaceSuggestionWindow = Self.makeCandidateWindow(
            contentViewController: replaceSuggestionsViewController,
            inputClient: textInputClient
        )

        // PromptInputWindowの初期化
        self.promptInputWindow = PromptInputWindow()

        super.init(server: server, delegate: delegate, client: inputClient)

        // デリゲートの設定を super.init の後に移動
        self.candidatesViewController.delegate = self
        self.replaceSuggestionsViewController.delegate = self
        self.segmentsManager.delegate = self
        self.setupMenu()
    }

    func currentRestartEpoch() -> UInt64 {
        self.restartEpoch
    }

    func shouldApplyAsyncResult(taskEpoch: UInt64) -> Bool {
        Self.shouldApplyAsyncResult(taskEpoch: taskEpoch, currentEpoch: self.restartEpoch)
    }

    func registerPromptPreviewTask(_ task: Task<Void, Never>) {
        self.promptPreviewTask?.cancel()
        self.promptPreviewTask = task
    }

    func clearPromptPreviewTask() {
        self.promptPreviewTask = nil
    }

    @MainActor
    func performPseudoRestart() {
        self.segmentsManager.appendDebugMessage("pseudo restart: 開始")
        self.restartEpoch &+= 1

        self.predictionHideWorkItem?.cancel()
        self.predictionHideWorkItem = nil
        self.replaceSuggestionTask?.cancel()
        self.replaceSuggestionTask = nil
        self.promptPreviewTask?.cancel()
        self.clearPromptPreviewTask()

        self.candidatesWindow.orderOut(nil)
        self.candidatesViewController.updateCandidatePresentations([], selectionIndex: nil, cursorLocation: .zero)
        self.candidatesViewController.hide()

        self.hidePredictionWindow()
        self.predictionViewController.updateCandidatePresentations([], selectionIndex: nil, cursorLocation: .zero)

        self.replaceSuggestionWindow.orderOut(nil)
        self.replaceSuggestionsViewController.updateCandidatePresentations([], selectionIndex: nil, cursorLocation: .zero)

        self.promptInputWindow.close()
        self.isPromptWindowVisible = false

        self.segmentsManager.stopComposition()
        self.segmentsManager.setReplaceSuggestions([])
        self.segmentsManager.resetSuggestionSelection()

        self.inputState = .none
        self.markedTextReplacementRange = nil
        self.retryCount = 0
        self.lastKey = (0, 0)

        self.refreshMarkedText()
        self.refreshCandidateWindow()
        self.refreshPredictionWindow()
        self.segmentsManager.appendDebugMessage("pseudo restart: 完了")
    }

    @MainActor
    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        // アプリケーションサポートのディレクトリを準備しておく
        self.prepareApplicationSupportDirectory()
        // Register custom input table (if available) for `.tableName` usage
        CustomInputTableStore.registerIfExists()
        self.updateLiveConversionToggleMenuItem(newValue: self.liveConversionEnabled)
        self.updateTransformSelectedTextMenuItemEnabledState()
        self.segmentsManager.activate()

        if let client = sender as? IMKTextInput {
            client.overrideKeyboard(withKeyboardNamed: Config.KeyboardLayout().value.layoutIdentifier)
            var rect: NSRect = .zero
            client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
            self.candidatesViewController.updateCandidatePresentations([], selectionIndex: nil, cursorLocation: rect.origin)
        } else {
            self.candidatesViewController.updateCandidatePresentations([], selectionIndex: nil, cursorLocation: .zero)
        }
        self.refreshCandidateWindow()
        self.refreshPredictionWindow()
    }

    @MainActor
    override func deactivateServer(_ sender: Any!) {
        self.segmentsManager.deactivate()
        self.candidatesWindow.orderOut(nil)
        self.predictionWindow.orderOut(nil)
        self.replaceSuggestionWindow.orderOut(nil)
        self.candidatesViewController.updateCandidatePresentations([], selectionIndex: nil, cursorLocation: .zero)
        super.deactivateServer(sender)
    }

    @MainActor
    override func commitComposition(_ sender: Any!) {
        // Unicode入力モードの場合は状態だけリセットして終了
        // マウスクリック等でOSがMarkedTextを確定した場合、IME側からは消せないため
        if case .unicodeInput = self.inputState {
            self.inputState = .none
            return
        }
        if self.segmentsManager.isEmpty {
            return
        }
        let reading = self.segmentsManager.convertTarget
        let text = self.segmentsManager.commitMarkedText(inputState: self.inputState)
        if let client = sender as? IMKTextInput {
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        self.recordLastCommittedText(text: text, reading: reading)
        self.inputState = .none
        self.refreshMarkedText()
        self.refreshCandidateWindow()
        self.refreshPredictionWindow()
    }

    // MARK: - setValue: 状態同期のみ
    @MainActor
    override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        defer {
            super.setValue(value, forTag: tag, client: sender)
        }

        if let value = value as? NSString {
            self.client()?.overrideKeyboard(withKeyboardNamed: Config.KeyboardLayout().value.layoutIdentifier)
            let englishMode = value == "com.apple.inputmethod.Roman"

            if englishMode {
                // 英語モードへの切り替え通知（実際の処理はhandleで行う）
                // メニューバー経由の切り替えに対応
                if self.inputLanguage == .japanese && self.segmentsManager.isEmpty {
                    self.inputLanguage = .english
                }
            } else {
                // 日本語モードへの切り替え
                if self.inputLanguage == .english {
                    self.inputLanguage = .japanese
                    let (clientAction, clientActionCallback) = self.inputState.event(
                        eventCore: .init(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 0x00),
                        userAction: .かな,
                        inputLanguage: self.inputLanguage,
                        liveConversionEnabled: false,
                        enableDebugWindow: false,
                        enableSuggestion: false
                    )
                    _ = self.handleClientAction(
                        clientAction,
                        clientActionCallback: clientActionCallback,
                        client: self.client()
                    )
                }
            }
        }
    }

    override func menu() -> NSMenu! {
        self.appMenu
    }

    private func isPrintable(_ text: String) -> Bool {
        let printable: CharacterSet = [.alphanumerics, .symbols, .punctuationCharacters]
            .reduce(into: CharacterSet()) {
                $0.formUnion($1)
            }
        return CharacterSet(text.unicodeScalars).isSubset(of: printable)
    }

    // swiftlint:disable:next cyclomatic_complexity
    @MainActor override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, let client = sender as? IMKTextInput else {
            return false
        }
        guard event.type == .keyDown else {
            return false
        }

        let userAction = UserAction.getUserAction(
            eventCore: event.keyEventCore,
            inputLanguage: inputLanguage,
            preserveASCIISymbolKeys: self.usesCustomInputTable
        )

        if self.handlePredictionCandidateSelectionIfNeeded(userAction) {
            return true
        }

        // 英数キー（keyCode 102）の処理
        if event.keyCode == 102 {
            let isDoubleTap = checkAndUpdateDoubleTap(keyCode: 102)

            if isDoubleTap {
                let selectedRange = client.selectedRange()
                if selectedRange.length > 0 {
                    if self.triggerAiTranslation(initialPrompt: "english") {
                        return true
                    }
                }
                if !self.segmentsManager.isEmpty {
                    _ = self.handleClientAction(.submitHalfWidthRomanCandidate, clientActionCallback: .transition(.none), client: client)
                    self.switchInputLanguage(.english, client: client)
                    return true
                }
            }
        }

        // かなキー（keyCode 104）の処理
        if event.keyCode == 104 {
            let isDoubleTap = checkAndUpdateDoubleTap(keyCode: 104)
            if isDoubleTap {
                #if AZOOKEY_ENABLE_KANA_DOUBLE_TAP_RECONVERT
                _ = self.handleClientAction(.reconvertCommittedText, clientActionCallback: .fallthrough, client: client)
                return true
                #else
                let selectedRange = client.selectedRange()
                if selectedRange.length > 0 {
                    if self.triggerAiTranslation(initialPrompt: "japanese") {
                        return true
                    }
                }
                #endif
            }
        }

        // Check if AI backend is enabled
        let aiBackendEnabled = Config.AIBackendPreference().value != .off

        // Handle suggest action with selected text check (prevent recursive calls)
        if case .suggest = userAction {
            // If AI backend is off, ignore the suggest action
            if !aiBackendEnabled {
                self.segmentsManager.appendDebugMessage("Suggest action ignored: AI backend is off")
                return false
            }

            // Prevent recursive window calls
            if self.isPromptWindowVisible {
                self.segmentsManager.appendDebugMessage("Suggest action ignored: prompt window already visible")
                return true
            }

            let selectedRange = client.selectedRange()
            self.segmentsManager.appendDebugMessage("Suggest action detected. Selected range: \(selectedRange)")
            if selectedRange.length > 0 {
                self.segmentsManager.appendDebugMessage("Selected text found, showing prompt input window")
                // There is selected text, show prompt input window
                return self.handleClientAction(.showPromptInputWindow, clientActionCallback: .fallthrough, client: client)
            } else {
                self.segmentsManager.appendDebugMessage("No selected text, using normal suggest behavior")
            }
        }

        let (clientAction, clientActionCallback) = inputState.event(
            eventCore: event.keyEventCore,
            userAction: userAction,
            inputLanguage: self.inputLanguage,
            liveConversionEnabled: Config.LiveConversion().value,
            enableDebugWindow: Config.DebugWindow().value,
            enableSuggestion: aiBackendEnabled
        )
        return handleClientAction(clientAction, clientActionCallback: clientActionCallback, client: client)
    }

    @MainActor
    private func handlePredictionCandidateSelectionIfNeeded(_ userAction: UserAction) -> Bool {
        guard self.inputState == .composing else {
            return false
        }
        guard self.predictionWindow.isVisible else {
            return false
        }
        guard case .navigation(let direction) = userAction else {
            return false
        }
        guard direction == .up || direction == .down else {
            return false
        }
        guard !self.lastPredictionCandidates.isEmpty else {
            return false
        }
        guard let nextIndex = Self.predictionSelectionIndex(
            current: self.predictionSelectionIndex,
            direction: direction,
            candidateCount: self.lastPredictionCandidates.count
        ) else {
            return false
        }
        self.predictionSelectionIndex = nextIndex
        self.predictionHideWorkItem?.cancel()
        self.predictionHideWorkItem = nil
        self.refreshPredictionWindow()
        return true
    }

    private var inputStyle: InputStyle {
        switch Config.InputStyle().value {
        case .default:
            .mapped(id: .defaultRomanToKana)
        case .defaultAZIK:
            .mapped(id: .defaultAZIK)
        case .defaultKanaUS:
            .mapped(id: .defaultKanaUS)
        case .defaultKanaJIS:
            .mapped(id: .defaultKanaJIS)
        case .custom:
            if CustomInputTableStore.exists() {
                .mapped(id: .tableName(CustomInputTableStore.tableName))
            } else {
                .mapped(id: .defaultRomanToKana)
            }
        }
    }

    private var usesCustomInputTable: Bool {
        guard case .mapped(let id) = self.inputStyle else {
            return false
        }
        guard case .tableName(let tableName) = id else {
            return false
        }
        return tableName == CustomInputTableStore.tableName
    }

    // この種のコードは複雑にしかならないので、lintを無効にする
    // swiftlint:disable:next cyclomatic_complexity
    @MainActor func handleClientAction(_ clientAction: ClientAction, clientActionCallback: ClientActionCallback, client: IMKTextInput) -> Bool {
        // return only false
        switch clientAction {
        case .showCandidateWindow:
            self.segmentsManager.requestSetCandidateWindowState(visible: true)
        case .hideCandidateWindow:
            self.segmentsManager.requestSetCandidateWindowState(visible: false)
        case .enterFirstCandidatePreviewMode:
            self.segmentsManager.insertCompositionSeparator(inputStyle: self.inputStyle, skipUpdate: false)
            self.segmentsManager.requestSetCandidateWindowState(visible: false)
        case .enterCandidateSelectionMode:
            self.segmentsManager.insertCompositionSeparator(inputStyle: self.inputStyle, skipUpdate: true)
            self.segmentsManager.update(requestRichCandidates: true)
        case .appendToMarkedText(let string):
            // 英語モードの場合は.directでローマ字変換せずそのまま入力
            let inputStyle: InputStyle = self.inputLanguage == .english ? .direct : self.inputStyle
            self.segmentsManager.insertAtCursorPosition(string, inputStyle: inputStyle)
        case .appendPieceToMarkedText(let pieces):
            // 英語モードの場合は.directでローマ字変換せずそのまま入力
            let inputStyle: InputStyle = self.inputLanguage == .english ? .direct : self.inputStyle
            self.segmentsManager.insertAtCursorPosition(pieces: pieces, inputStyle: inputStyle)
        case .insertWithoutMarkedText(let string):
            client.insertText(string, replacementRange: NSRange(location: NSNotFound, length: 0))
        case .editSegment(let count):
            self.segmentsManager.editSegment(count: count)
        case .commitMarkedText:
            let reading = self.segmentsManager.convertTarget
            let text = self.segmentsManager.commitMarkedText(inputState: self.inputState)
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            self.recordLastCommittedText(text: text, reading: reading)
        case .commitMarkedTextAndAppendToMarkedText(let string):
            let reading = self.segmentsManager.convertTarget
            let text = self.segmentsManager.commitMarkedText(inputState: self.inputState)
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            self.recordLastCommittedText(text: text, reading: reading)
            // 英語モードの場合は.directでローマ字変換せずそのまま入力
            let inputStyle: InputStyle = self.inputLanguage == .english ? .direct : self.inputStyle
            self.segmentsManager.insertAtCursorPosition(string, inputStyle: inputStyle)
        case .commitMarkedTextAndAppendPieceToMarkedText(let pieces):
            let reading = self.segmentsManager.convertTarget
            let text = self.segmentsManager.commitMarkedText(inputState: self.inputState)
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            self.recordLastCommittedText(text: text, reading: reading)
            // 英語モードの場合は.directでローマ字変換せずそのまま入力
            let inputStyle: InputStyle = self.inputLanguage == .english ? .direct : self.inputStyle
            self.segmentsManager.insertAtCursorPosition(pieces: pieces, inputStyle: inputStyle)
        case .submitSelectedCandidate:
            self.submitSelectedCandidate()
        case .removeLastMarkedText:
            self.segmentsManager.deleteBackwardFromCursorPosition()
            self.segmentsManager.requestResettingSelection()
        case .selectPrevCandidate:
            self.segmentsManager.requestSelectingPrevCandidate()
        case .selectNextCandidate:
            self.segmentsManager.requestSelectingNextCandidate()
        case .selectPrevCandidatePage:
            self.candidatesViewController.requestAlignSelectionToPageBoundary()
            self.segmentsManager.requestSelectingPrevCandidatePage(pageSize: max(1, self.candidatesViewController.numberOfVisibleRows))
        case .selectNextCandidatePage:
            self.candidatesViewController.requestAlignSelectionToPageBoundary()
            self.segmentsManager.requestSelectingNextCandidatePage(pageSize: max(1, self.candidatesViewController.numberOfVisibleRows))
        case .selectFirstCandidate:
            self.segmentsManager.requestSelectingFirstCandidate()
        case .selectLastCandidate:
            self.segmentsManager.requestSelectingLastCandidate()
        case .selectNumberCandidate(let num):
            self.segmentsManager.requestSelectingRow(self.candidatesViewController.getNumberCandidate(num: num))
            self.submitSelectedCandidate()
            self.segmentsManager.requestResettingSelection()
        case .submitHiraganaCandidate:
            self.submitCandidate(self.segmentsManager.getModifiedRubyCandidate(inputState: self.inputState) {
                $0.toHiragana()
            })
        case .submitKatakanaCandidate:
            self.submitCandidate(self.segmentsManager.getModifiedRubyCandidate(inputState: self.inputState) {
                $0.toKatakana()
            })
        case .submitHankakuKatakanaCandidate:
            self.submitCandidate(self.segmentsManager.getModifiedRubyCandidate(inputState: self.inputState) {
                $0.toKatakana().applyingTransform(.fullwidthToHalfwidth, reverse: false)!
            })
        case .submitFullWidthRomanCandidate:
            self.submitCandidate(self.segmentsManager.getModifiedRomanCandidate {
                $0.applyingTransform(.fullwidthToHalfwidth, reverse: true)!
            })
        case .submitHalfWidthRomanCandidate:
            self.submitCandidate(self.segmentsManager.getModifiedRomanCandidate {
                $0.applyingTransform(.fullwidthToHalfwidth, reverse: false)!
            })
        case .enableDebugWindow:
            self.segmentsManager.requestDebugWindowMode(enabled: true)
        case .disableDebugWindow:
            self.segmentsManager.requestDebugWindowMode(enabled: false)
        case .stopComposition:
            self.segmentsManager.stopComposition()
        case .forgetMemory:
            self.segmentsManager.forgetMemory()
        case .selectInputLanguage(let language):
            self.switchInputLanguage(language, client: client)
        case .commitMarkedTextAndSelectInputLanguage(let language):
            let reading = self.segmentsManager.convertTarget
            let text = self.segmentsManager.commitMarkedText(inputState: self.inputState)
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            self.recordLastCommittedText(text: text, reading: reading)
            self.switchInputLanguage(language, client: client)
        // PredictiveSuggestion
        case .requestPredictiveSuggestion:
            // 「つづき」を直接入力し、コンテキストを渡す
            self.segmentsManager.insertAtCursorPosition("つづき", inputStyle: self.inputStyle)
            self.requestReplaceSuggestion()
        case .acceptPredictionCandidate:
            self.acceptPredictionCandidate()
        // ReplaceSuggestion
        case .requestReplaceSuggestion:
            self.requestReplaceSuggestion()
        case .selectNextReplaceSuggestionCandidate:
            self.replaceSuggestionsViewController.selectNextCandidate()
        case .selectPrevReplaceSuggestionCandidate:
            self.replaceSuggestionsViewController.selectPrevCandidate()
        case .submitReplaceSuggestionCandidate:
            self.submitSelectedSuggestionCandidate()
        case .hideReplaceSuggestionWindow:
            self.replaceSuggestionWindow.setIsVisible(false)
            self.replaceSuggestionWindow.orderOut(nil)
        // Selected Text Transform
        case .showPromptInputWindow:
            self.segmentsManager.appendDebugMessage("Executing showPromptInputWindow")
            self.showPromptInputWindow()
        case .transformSelectedText(let selectedText, let prompt):
            self.segmentsManager.appendDebugMessage("Executing transformSelectedText with text: '\(selectedText)' and prompt: '\(prompt)'")
            self.transformSelectedText(selectedText: selectedText, prompt: prompt)
        case .reconvertCommittedText:
            _ = self.reconvertCommittedText(client: client)
        // Unicode Input (Shift+Ctrl+U)
        case .enterUnicodeInputMode:
            // 状態遷移は clientActionCallback で行われるので、ここでは何もしない
            break
        case .appendToUnicodeInput:
            // markedText の更新は refreshMarkedText で行われる
            break
        case .removeLastUnicodeInput:
            // markedText の更新は refreshMarkedText で行われる
            break
        case .submitUnicodeInput(let codePoint):
            if let scalar = UInt32(codePoint, radix: 16), let unicodeScalar = Unicode.Scalar(scalar) {
                let character = String(Character(unicodeScalar))
                client.insertText(character, replacementRange: NSRange(location: NSNotFound, length: 0))
                self.recordLastCommittedText(text: character)
            }
        case .cancelUnicodeInput:
            // 状態遷移は clientActionCallback で行われるので、ここでは何もしない
            break
        case .submitSelectedCandidateAndEnterUnicodeInputMode:
            // 選択中の候補を確定
            self.submitSelectedCandidate()
            // 残りのテキストがあればひらがなのまま確定
            if !self.segmentsManager.isEmpty {
                let text = self.segmentsManager.convertTarget
                client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                self.recordLastCommittedText(text: text, reading: text)
                self.segmentsManager.stopComposition()
            }
        // MARK: 特殊ケース
        case .consume:
            // 何もせず先に進む
            break
        case .fallthrough:
            return false
        }

        switch clientActionCallback {
        case .fallthrough:
            break
        case .transition(let inputState):
            // 遷移した時にreplaceSuggestionWindowをhideする
            if inputState != .replaceSuggestion {
                self.replaceSuggestionWindow.orderOut(nil)
            }
            if inputState == .none {
                self.switchInputLanguage(self.inputLanguage, client: client)
            }
            self.inputState = inputState
        case .basedOnBackspace(let ifIsEmpty, let ifIsNotEmpty), .basedOnSubmitCandidate(let ifIsEmpty, let ifIsNotEmpty):
            self.inputState = self.segmentsManager.isEmpty ? ifIsEmpty : ifIsNotEmpty
        }

        self.refreshMarkedText()
        self.refreshCandidateWindow()
        self.refreshPredictionWindow()
        return true
    }

    @MainActor func switchInputLanguage(_ language: InputLanguage, client: IMKTextInput) {
        self.inputLanguage = language
        client.overrideKeyboard(withKeyboardNamed: Config.KeyboardLayout().value.layoutIdentifier)
        switch language {
        case .english:
            client.selectMode("dev.lpm11.inputmethod.azooKeyMac.Roman")
            self.segmentsManager.stopJapaneseInput()
        case .japanese:
            client.selectMode("dev.lpm11.inputmethod.azooKeyMac.Japanese")
        }
    }

    func refreshCandidateWindow() {
        switch self.segmentsManager.getCurrentCandidateWindow(inputState: self.inputState) {
        case .selecting(let candidates, let selectionIndex):
            var rect: NSRect = .zero
            self.client().attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
            self.candidatesViewController.showCandidateIndex = true
            let candidatePresentations = self.segmentsManager.makeCandidatePresentations(candidates)
            self.candidatesViewController.updateCandidatePresentations(
                candidatePresentations,
                selectionIndex: selectionIndex,
                cursorLocation: rect.origin
            )
            self.candidatesWindow.orderFront(nil)
        case .composing(let candidates, let selectionIndex):
            var rect: NSRect = .zero
            self.client().attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
            self.candidatesViewController.showCandidateIndex = false
            let candidatePresentations = self.segmentsManager.makeCandidatePresentations(candidates)
            self.candidatesViewController.updateCandidatePresentations(
                candidatePresentations,
                selectionIndex: selectionIndex,
                cursorLocation: rect.origin
            )
            self.candidatesWindow.orderFront(nil)
        case .hidden:
            self.candidatesWindow.setIsVisible(false)
            self.candidatesWindow.orderOut(nil)
            self.candidatesViewController.hide()
        }
    }

    func refreshPredictionWindow() {
        guard self.inputState == .composing else {
            self.hidePredictionWindow()
            return
        }

        let predictions = self.segmentsManager.requestPredictionCandidates()
        if predictions.isEmpty {
            if !self.lastPredictionCandidates.isEmpty {
                self.showCachedPredictionWindow()
                if self.predictionSelectionIndex == nil {
                    let now = Date().timeIntervalSince1970
                    let elapsed = now - self.lastPredictionUpdateTime
                    if elapsed < 1.0 {
                        self.schedulePredictionHide(after: max(0, 1.0 - elapsed))
                    } else {
                        self.hidePredictionWindow()
                    }
                } else {
                    self.predictionHideWorkItem?.cancel()
                    self.predictionHideWorkItem = nil
                }
                return
            }
            self.hidePredictionWindow()
            return
        }

        self.predictionHideWorkItem?.cancel()
        self.predictionHideWorkItem = nil
        self.lastPredictionCandidates = predictions
        self.lastPredictionUpdateTime = Date().timeIntervalSince1970

        let selectionIndex = self.normalizedPredictionSelectionIndex(candidateCount: predictions.count)
        let candidates = predictions.map { prediction in
            Candidate(
                text: prediction.displayText,
                value: 0,
                composingCount: .surfaceCount(prediction.displayText.count),
                lastMid: 0,
                data: []
            )
        }

        var rect: NSRect = .zero
        self.client().attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        self.predictionViewController.updateCandidatePresentations(
            candidates.map { .init(candidate: $0) },
            selectionIndex: selectionIndex,
            cursorLocation: rect.origin
        )

        if Config.LiveConversion().value {
            self.predictionWindow.orderFront(nil)
            return
        }

        if self.candidatesWindow.isVisible {
            self.positionPredictionWindowRightOfCandidateWindow()
        }
        self.predictionWindow.orderFront(nil)
    }

    private func positionPredictionWindowRightOfCandidateWindow(gap: CGFloat = 8) {
        guard let screen = self.predictionWindow.screen ?? self.candidatesWindow.screen else {
            return
        }

        let frame = WindowPositioning.frameRightOfAnchor(
            currentFrame: WindowPositioning.Rect(self.predictionWindow.frame),
            anchorFrame: WindowPositioning.Rect(self.candidatesWindow.frame),
            screenRect: WindowPositioning.Rect(screen.visibleFrame),
            gap: Double(gap)
        )
        self.predictionWindow.setFrame(frame.cgRect, display: true)
    }

    private func showCachedPredictionWindow() {
        let selectionIndex = self.normalizedPredictionSelectionIndex(candidateCount: self.lastPredictionCandidates.count)
        let candidates = self.lastPredictionCandidates.map { prediction in
            Candidate(
                text: prediction.displayText,
                value: 0,
                composingCount: .surfaceCount(prediction.displayText.count),
                lastMid: 0,
                data: []
            )
        }
        guard !candidates.isEmpty else {
            return
        }
        var rect: NSRect = .zero
        self.client().attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        self.predictionViewController.updateCandidatePresentations(
            candidates.map { .init(candidate: $0) },
            selectionIndex: selectionIndex,
            cursorLocation: rect.origin
        )
        self.predictionWindow.orderFront(nil)
    }

    private func normalizedPredictionSelectionIndex(candidateCount: Int) -> Int? {
        guard candidateCount > 0 else {
            self.predictionSelectionIndex = nil
            return nil
        }
        guard let predictionSelectionIndex else {
            return nil
        }
        let normalized = max(0, min(predictionSelectionIndex, candidateCount - 1))
        self.predictionSelectionIndex = normalized
        return normalized
    }

    private func schedulePredictionHide(after delay: TimeInterval) {
        self.predictionHideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            guard self.predictionSelectionIndex == nil else {
                return
            }
            let now = Date().timeIntervalSince1970
            if now - self.lastPredictionUpdateTime >= 1.0 {
                self.hidePredictionWindow()
            }
        }
        self.predictionHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func hidePredictionWindow() {
        self.predictionWindow.setIsVisible(false)
        self.predictionWindow.orderOut(nil)
        self.lastPredictionCandidates = []
        self.predictionSelectionIndex = nil
        self.lastPredictionUpdateTime = 0
        self.predictionHideWorkItem?.cancel()
        self.predictionHideWorkItem = nil
    }

    @MainActor
    private func acceptPredictionCandidate() {
        let predictionCandidates = self.segmentsManager.requestPredictionCandidates()
        let predictions: [SegmentsManager.PredictionCandidate]
        if predictionCandidates.isEmpty {
            predictions = self.lastPredictionCandidates
        } else {
            predictions = predictionCandidates
            self.lastPredictionCandidates = predictionCandidates
            self.lastPredictionUpdateTime = Date().timeIntervalSince1970
        }
        guard !predictions.isEmpty else {
            return
        }
        let selectedIndex = self.normalizedPredictionSelectionIndex(candidateCount: predictions.count) ?? 0
        let prediction = predictions[selectedIndex]
        self.predictionSelectionIndex = nil

        let currentTarget = self.segmentsManager.convertTarget
        var matchTarget = currentTarget
        if let last = matchTarget.last,
           last.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.letters.contains($0) }) {
            matchTarget.removeLast()
            self.segmentsManager.deleteBackwardFromCursorPosition(count: 1)
        }

        guard !matchTarget.isEmpty else {
            return
        }

        let appendText = prediction.appendText

        guard !appendText.isEmpty else {
            return
        }

        self.segmentsManager.insertAtCursorPosition(appendText, inputStyle: .direct)
        self.segmentsManager.prioritizeMainResult(text: prediction.displayText)
    }

    var retryCount = 0
    let maxRetries = 3

    @MainActor func handleSuggestionError(_ error: Error, cursorPosition: CGPoint) {
        let errorMessage = "エラーが発生しました: \(error.localizedDescription)"
        self.segmentsManager.appendDebugMessage(errorMessage)
    }

    func getCursorLocation() -> CGPoint {
        var rect: NSRect = .zero
        self.client()?.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        self.segmentsManager.appendDebugMessage("カーソル位置取得: \(rect.origin)")
        return rect.origin
    }

    func refreshMarkedText() {
        let highlight = self.mark(
            forStyle: kTSMHiliteSelectedConvertedText,
            at: NSRange(location: NSNotFound, length: 0)
        ) as? [NSAttributedString.Key: Any]
        let underline = self.mark(
            forStyle: kTSMHiliteConvertedText,
            at: NSRange(location: NSNotFound, length: 0)
        ) as? [NSAttributedString.Key: Any]
        let text = NSMutableAttributedString(string: "")
        let currentMarkedText = self.segmentsManager.getCurrentMarkedText(inputState: self.inputState)
        for part in currentMarkedText where !part.content.isEmpty {
            let attributes: [NSAttributedString.Key: Any]? = switch part.focus {
            case .focused: highlight
            case .unfocused: underline
            case .none: [:]
            }
            text.append(
                NSAttributedString(
                    string: part.content,
                    attributes: attributes
                )
            )
        }
        let replacementRange = self.markedTextReplacementRange ?? NSRange(location: NSNotFound, length: 0)
        self.markedTextReplacementRange = nil
        self.client()?.setMarkedText(
            text,
            selectionRange: currentMarkedText.selectionRange,
            replacementRange: replacementRange
        )
    }

    @MainActor
    func submitCandidate(_ candidate: Candidate) {
        if let client = self.client() {
            // インサートを行う前にコンテキストを取得する
            let cleanLeftSideContext = self.segmentsManager.getCleanLeftSideContext(maxCount: 30)
            client.insertText(candidate.text, replacementRange: NSRange(location: NSNotFound, length: 0))
            self.recordLastCommittedText(text: candidate.text, reading: self.reading(from: candidate))
            // アプリケーションサポートのディレクトリを準備しておく
            self.segmentsManager.prefixCandidateCommited(candidate, leftSideContext: cleanLeftSideContext ?? "")
        }
    }

    @MainActor
    func submitSelectedCandidate() {
        if let candidate = self.segmentsManager.selectedCandidate {
            self.submitCandidate(candidate)
            self.segmentsManager.requestResettingSelection()
        }
    }
}

extension azooKeyMacInputController: CandidatesViewControllerDelegate {
    func candidateSubmitted() {
        Task { @MainActor in
            self.submitSelectedCandidate()
        }
    }

    func candidateSelectionChanged(_ row: Int) {
        Task { @MainActor in
            self.segmentsManager.requestSelectingRow(row)
        }
    }
}

extension azooKeyMacInputController: SegmentManagerDelegate {
    func getLeftSideContext(maxCount: Int) -> String? {
        let endIndex = client().markedRange().location
        let leftRange = NSRange(location: max(endIndex - maxCount, 0), length: min(endIndex, maxCount))
        var actual = NSRange()
        // 同じ行の文字のみコンテキストに含める
        let leftSideContext = self.client().string(from: leftRange, actualRange: &actual)
        self.segmentsManager.appendDebugMessage("\(#function): leftSideContext=\(leftSideContext ?? "nil")")
        return leftSideContext
    }
}

extension azooKeyMacInputController: ReplaceSuggestionsViewControllerDelegate {
    @MainActor func replaceSuggestionSelectionChanged(_ row: Int) {
        self.segmentsManager.requestSelectingSuggestionRow(row)
    }

    func replaceSuggestionSubmitted() {
        Task { @MainActor in
            if let candidate = self.replaceSuggestionsViewController.getSelectedCandidate() {
                if let client = self.client() {
                    // 選択された候補をテキストとして挿入
                    client.insertText(candidate.text, replacementRange: NSRange(location: NSNotFound, length: 0))
                    self.recordLastCommittedText(text: candidate.text, reading: self.reading(from: candidate))
                    // サジェスト候補ウィンドウを非表示にする
                    self.replaceSuggestionWindow.setIsVisible(false)
                    self.replaceSuggestionWindow.orderOut(nil)
                    // 変換状態をリセット
                    self.segmentsManager.stopComposition()
                }
            }
        }
    }
}

// Suggest Candidate
extension azooKeyMacInputController {
    // MARK: - Replace Suggestion Request Handling
    @MainActor func requestReplaceSuggestion() {
        self.segmentsManager.appendDebugMessage("requestReplaceSuggestion: 開始")
        let requestEpoch = self.restartEpoch

        // リクエスト開始時に前回の候補をクリアし、ウィンドウを非表示にする
        self.segmentsManager.setReplaceSuggestions([])
        self.segmentsManager.resetSuggestionSelection()
        self.replaceSuggestionWindow.setIsVisible(false)
        self.replaceSuggestionWindow.orderOut(nil)

        // Get selected backend preference
        let preference = Config.AIBackendPreference().value

        // If backend is off, do nothing
        if preference == .off {
            self.segmentsManager.appendDebugMessage("AI backend is off, skipping suggestion")
            return
        }

        let composingText = self.segmentsManager.convertTarget

        // プロンプトを取得
        let prompt = self.getLeftSideContext(maxCount: 100) ?? ""

        self.segmentsManager.appendDebugMessage("プロンプト取得成功: \(prompt) << \(composingText)")

        let apiKey = Config.OpenAiApiKey().value
        let modelName = Config.OpenAiModelName().value
        let request = OpenAIRequest(prompt: prompt, target: composingText, modelName: modelName)
        self.segmentsManager.appendDebugMessage("APIリクエスト準備完了: prompt=\(prompt), target=\(composingText), modelName=\(modelName)")

        // Get selected backend
        let backend: AIBackend
        switch preference {
        case .off:
            // Already checked above, but defensive programming
            self.segmentsManager.appendDebugMessage("Unexpected .off state in backend selection")
            return
        case .foundationModels:
            backend = .foundationModels
        case .openAI:
            backend = .openAI
        }
        self.segmentsManager.appendDebugMessage("Using backend: \(backend.rawValue)")

        self.startReplaceSuggestionTask(
            request: request,
            backend: backend,
            apiKey: apiKey,
            composingText: composingText,
            requestEpoch: requestEpoch
        )
        self.segmentsManager.appendDebugMessage("requestReplaceSuggestion: 終了")
    }

    @MainActor
    private func startReplaceSuggestionTask(
        request: OpenAIRequest,
        backend: AIBackend,
        apiKey: String,
        composingText: String,
        requestEpoch: UInt64
    ) {
        self.replaceSuggestionTask?.cancel()
        self.replaceSuggestionTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                self.segmentsManager.appendDebugMessage("APIリクエスト送信中...")
                let predictions = try await AIClient.sendRequest(
                    request,
                    backend: backend,
                    apiKey: apiKey,
                    apiEndpoint: Config.OpenAiApiEndpoint().value,
                    logger: { [weak self] message in
                        self?.segmentsManager.appendDebugMessage(message)
                    }
                )
                self.segmentsManager.appendDebugMessage("APIレスポンス受信成功: \(predictions)")
                guard !Task.isCancelled else {
                    return
                }

                let candidates = predictions.map { text in
                    Candidate(
                        text: text,
                        value: PValue(0),
                        composingCount: .surfaceCount(composingText.count),
                        lastMid: 0,
                        data: [],
                        actions: [],
                        inputable: true
                    )
                }

                self.segmentsManager.appendDebugMessage("候補変換成功: \(candidates.map { $0.text })")

                await MainActor.run {
                    guard self.shouldApplyAsyncResult(taskEpoch: requestEpoch) else {
                        self.segmentsManager.appendDebugMessage("requestReplaceSuggestion: stale result ignored (epoch mismatch)")
                        return
                    }
                    self.segmentsManager.appendDebugMessage("候補ウィンドウ更新中...")
                    if !candidates.isEmpty {
                        self.segmentsManager.setReplaceSuggestions(candidates)
                        self.replaceSuggestionsViewController.updateCandidatePresentations(
                            candidates.map { .init(candidate: $0) },
                            selectionIndex: nil,
                            cursorLocation: getCursorLocation()
                        )
                        self.replaceSuggestionWindow.setIsVisible(true)
                        self.replaceSuggestionWindow.makeKeyAndOrderFront(nil)
                        self.segmentsManager.appendDebugMessage("候補ウィンドウ更新完了")
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.segmentsManager.appendDebugMessage("requestReplaceSuggestion: cancelled")
                }
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                let errorMessage = "APIリクエストエラー: \(error.localizedDescription)"
                self.segmentsManager.appendDebugMessage(errorMessage)
                await MainActor.run {
                    guard self.shouldApplyAsyncResult(taskEpoch: requestEpoch) else {
                        self.segmentsManager.appendDebugMessage("requestReplaceSuggestion: stale error ignored (epoch mismatch)")
                        return
                    }
                    let alert = NSAlert()
                    alert.messageText = "変換に失敗しました"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    // MARK: - Window Management
    @MainActor func hideReplaceSuggestionCandidateView() {
        self.replaceSuggestionWindow.setIsVisible(false)
        self.replaceSuggestionWindow.orderOut(nil)
    }

    @MainActor func submitSelectedSuggestionCandidate() {
        if let candidate = self.replaceSuggestionsViewController.getSelectedCandidate() {
            if let client = self.client() {
                client.insertText(candidate.text, replacementRange: NSRange(location: NSNotFound, length: 0))
                self.recordLastCommittedText(text: candidate.text, reading: self.reading(from: candidate))
                self.replaceSuggestionWindow.setIsVisible(false)
                self.replaceSuggestionWindow.orderOut(nil)
                self.segmentsManager.stopComposition()
            }
        }
    }

    // MARK: - Helper Methods
    private func retrySuggestionRequestIfNeeded(cursorPosition: CGPoint) {
        if retryCount < maxRetries {
            retryCount += 1
            self.segmentsManager.appendDebugMessage("再試行中... (\(retryCount)回目)")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.requestReplaceSuggestion()
            }
        } else {
            self.segmentsManager.appendDebugMessage("再試行上限に達しました。")
            retryCount = 0
        }
    }

}
