# 「確定文字列を再変換」設計メモ

参考: 「かわせみ」IME の「確定文字を再変換」機能。

## 目的

azooKey-Desktop に、確定済みテキストを再び変換中状態に戻す機能を追加する。
v1 では以下 2 機能に限定する。

- 直前確定の取り消し・再変換
- 選択範囲の再変換

以下は v1 の対象外（将来課題）。

- 現在文節の再変換（カーソル位置から文節を推定して再変換）

## 機能概要（v1）

### 1. 直前確定の取り消し・再変換

- 条件:
  - 現在選択範囲が空 (`selectedRange.length == 0`)
  - 直前に azooKey が `insertText` で確定した文字列情報を保持している
  - カーソル直前の実テキストが保持した確定文字列と一致する
- 動作:
  - 一致した範囲を `replacementRange` で削除
  - 同文字列を `SegmentsManager.insertAtCursorPosition` で再投入
  - `inputState = .composing` に遷移
  - `refreshMarkedText()` / 候補更新を実行

### 2. 選択範囲の再変換

- 条件:
  - `selectedRange.length > 0`
- 動作:
  - `client.string(from:selectedRange, ...)` で選択文字列を取得
  - `insertText("", replacementRange:selectedRange)` 相当で選択範囲を削除
  - 取得文字列を変換中として再投入
  - `inputState = .composing` に遷移

### 優先順位

- キーバインド発火時の判定順は以下:
  1. 選択範囲があれば「選択範囲の再変換」
  2. 選択範囲がなければ「直前確定の取り消し・再変換」
  3. どちらも条件を満たさない場合は no-op（`false` または consume）

## キーバインド仕様

- `Ctrl-Shift-R` を追加
- `かな` 2 回連続押しもトリガー候補とする
  - ただし既存の「和訳トリガー（かなダブルタップ）」と衝突するため、コンパイル時フラグで切り替える

## コンパイル時フラグ方針

`かな` ダブルタップの役割をビルド時に固定する。

- `AZOOKEY_ENABLE_KANA_DOUBLE_TAP_RECONVERT=1`
  - ON: かなダブルタップは再変換トリガーとして扱う
  - OFF: 従来どおり和訳トリガーとして扱う

実装候補:

- `azooKeyMacInputController.handle(_:client:)` の `keyCode == 104` 分岐を `#if AZOOKEY_ENABLE_KANA_DOUBLE_TAP_RECONVERT` で分岐
- `Ctrl-Shift-R` は `UserAction` に新アクションを追加して常時有効

## 実装方針

## A. Core の変更

- `UserAction` に再変換用アクションを追加（例: `.reconvertCommittedText`）
  - マッピング: `charactersIgnoringModifiers == "r"` かつ `modifierFlags == [.control, .shift]`
- `ClientAction` に再変換実行アクションを追加（例: `.reconvertCommittedText`）
- `InputState.event(...)` に遷移を追加
  - `none/composing/previewing/selecting` など主要状態で受理
  - callback は `.fallthrough` or `.transition(.composing)` を実装都合で選択

## B. macOS InputController の変更

- `azooKeyMacInputController` に「直前確定情報」保持フィールドを追加
  - 例: `lastCommittedText: String?`
  - 必要なら `lastCommittedDate` / `sourceState`（任意）
- azooKey が確定文字列を `insertText` する全経路で履歴を更新
  - `commitComposition`
  - `.commitMarkedText` 系の `handleClientAction`
  - `submitCandidate` など候補確定経路
- 新アクション受信時の処理を追加
  - 選択範囲再変換
  - 直前確定再変換

## C. テキスト置換の実装詳細

- 再変換開始前に IMK クライアントから対象テキストを再読して一致確認する
- 削除は `insertText("", replacementRange: targetRange)` を第一候補とする
- アプリ差異で失敗するケースに備えてログを残し、失敗時は状態変更を行わない

## D. 入力スタイル

- 再投入時は現行実装との整合を優先し、原則 `self.inputStyle` を利用
- 英語入力モード中の扱いは仕様で明示する（候補: 強制日本語再変換のため `.mapped` 系を使用）

## 非機能要件・制約

- `selectedRange` / `string(from:)` はアプリごとに挙動差があるため、失敗時に安全に no-op へ倒す
- `NSRange` は UTF-16 基準なので `String.count` と直接混同しない
- 不整合時に誤削除しないことを最優先にする

## テスト方針（v1）

- Unit（可能な範囲）
  - `UserAction` の `Ctrl-Shift-R` マッピング
  - `InputState` のアクション遷移
- Manual（必須）
  - `直前確定 -> 再変換` が主要アプリ（TextEdit, Notes, VS Code など）で成立
  - `選択範囲 -> 再変換` が成立
  - 対象不一致時に誤削除しない
  - かなダブルタップの動作がコンパイル時フラグで切替わる

## 今後の課題

- 現在文節の再変換
  - カーソル位置からの文節推定
  - 形態素解析導入有無の検討（NaturalLanguage 単体では日本語品詞分類が限定的）

## 対象コード（想定）

- `Core/Sources/Core/InputUtils/Actions/UserAction.swift`
- `Core/Sources/Core/InputUtils/Actions/ClientAction.swift`
- `Core/Sources/Core/InputUtils/InputState.swift`
- `azooKeyMac/InputController/azooKeyMacInputController.swift`
- 必要に応じて `KEYBINDINGS.md`
