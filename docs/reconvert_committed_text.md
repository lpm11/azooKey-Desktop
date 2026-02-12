# 「確定文字列を再変換」実装メモ（v1）

`plans/reconvert_committed_text.md` から移動し、実装後の内容に更新。

## 目的

azooKey-Desktop で、確定済みテキストを再び変換中状態に戻せるようにする。

## 実装済み機能（v1）

- 直前確定の取り消し・再変換
- 選択範囲の再変換
- 選択範囲の読み推定（Apple API ベース）

## キーバインド

- `Ctrl-Shift-R` で再変換
- `かな` ダブルタップはコンパイル時フラグで切替
  - `AZOOKEY_ENABLE_KANA_DOUBLE_TAP_RECONVERT=1`: 再変換
  - `AZOOKEY_ENABLE_KANA_DOUBLE_TAP_RECONVERT=0`: 従来どおり和訳トリガー

現状は `AZOOKEY_ENABLE_KANA_DOUBLE_TAP_RECONVERT` をデフォルト有効。

## 仕様（実装後）

### 1. 選択範囲の再変換

条件:
- `selectedRange.length > 0`

動作:
- `client.string(from:selectedRange, actualRange:)` で選択文字列を取得
- 選択文字列から「読み」を推定して再投入（推定できない場合は元文字列を使う）
- `inputState = .composing`

実装上のポイント:
- 単純な `insertText("", replacementRange: selectedRange)` は使わず、`setMarkedText(..., replacementRange: selectedRange)` の置換経路で開始する
- 読み推定は Apple API (`CFStringTokenizer`) を利用
  - 背景: 選択範囲再変換は「直前確定再変換」と異なり、確定時の読み履歴を持たない
  - 文字列を ASCII 連続区間 / 非 ASCII 連続区間に分割し、ASCII 区間は原文のまま保持する
  - `ja` ロケール + `kCFStringTokenizerAttributeLatinTranscription` を取得し、`.latinToHiragana` でひらがな化
  - 記号・空白のみトークンは原文維持
  - 変換不能トークンは原文維持
  - `ABC` などの ASCII を無条件変換すると `あぶく` のような意図しない結果になりうるため、ASCII 区間は推定対象外にしている

### 2. 直前確定の取り消し・再変換

条件:
- `selectedRange.length == 0`
- 直前確定履歴（`LastCommittedEntry`）がある
- カーソル直前の文字列が `lastCommittedEntry.text` と一致

動作:
- 対象 `NSRange` を UTF-16 長で算出
- `client.string(from:targetRange, actualRange:)` で再読・一致確認
- 一致時のみ、`lastCommittedEntry.reading` を変換中テキストとして再投入
- `inputState = .composing`

## 直前確定履歴の保持

保持する情報:
- `text`: 実際に確定した文字列
- `reading`: 再変換に再投入する読み（候補の ruby など）

更新タイミング:
- `commitComposition`
- `.commitMarkedText` 系の `handleClientAction`
- `submitCandidate`（候補確定）
- suggestion 候補確定
- Unicode 入力確定

## 元計画からの主な変更点

### 変更1: 再変換開始時の置換方法

元計画:
- `insertText("", replacementRange: targetRange)` で削除してから再投入

実装変更:
- `setMarkedText(..., replacementRange: targetRange)` を使う方式へ変更

理由:
- `insertText` による削除が安定せず、削除失敗時に再投入だけ行われて二重化するため

### 変更2: 履歴に「読み」を保持

元計画:
- `lastCommittedText` 中心

実装変更:
- `LastCommittedEntry(text, reading)` へ拡張

理由:
- 「直前確定の取り消し・再変換」で、確定済み表示文字列ではなく入力読みを再投入したいケースに対応するため

## `insertText` / `setMarkedText` 整理

`NSTextInputClient`（AppKit）の定義上:
- `insertText:replacementRange:` は、指定範囲を置換して文字列を挿入する API
- `setMarkedText:selectedRange:replacementRange:` は、指定範囲を置換して marked text（未確定テキスト）を設定する API

再変換は「未確定状態へ戻す」操作なので、最終的に `setMarkedText` ベースの経路に寄せる方が IME の責務に沿う。

参考:
- https://developer.apple.com/documentation/appkit/nstextinputclient/inserttext(_:replacementrange:)
- https://developer.apple.com/documentation/appkit/nstextinputclient/setmarkedtext(_:selectedrange:replacementrange:)
- `MacOSX.sdk/System/Library/Frameworks/AppKit.framework/Headers/NSTextInputClient.h`

## 非機能要件・制約

- `selectedRange` / `string(from:)` の挙動はアプリ差があるため、取得失敗時は no-op
- `NSRange` は UTF-16 基準で扱う
- 不一致時に誤削除しないことを優先

## テスト状況

Unit:
- `UserAction` の `Ctrl-Shift-R` マッピング
- `InputState` の再変換アクション受理（主要状態）

## 対象コード

- `Core/Sources/Core/InputUtils/Actions/UserAction.swift`
- `Core/Sources/Core/InputUtils/Actions/ClientAction.swift`
- `Core/Sources/Core/InputUtils/InputState.swift`
- `azooKeyMac/InputController/azooKeyMacInputController.swift`
- `azooKeyMac.xcodeproj/project.pbxproj`
- `KEYBINDINGS.md`
- `Core/Tests/CoreTests/InputUtilsTests/UserActionReconvertShortcutTests.swift`
- `Core/Tests/CoreTests/InputUtilsTests/InputStateReconvertCommittedTextTests.swift`

## 将来課題

- 現在文節の再変換
- アプリ差の追加吸収（必要に応じてフォールバック戦略を追加）
