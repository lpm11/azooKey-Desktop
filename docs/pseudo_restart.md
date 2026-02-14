# 擬似再起動（Pseudo Restart）設計メモ

## 動機

Mac の IME は「再起動」が困難なため、入力中に候補ウィンドウ（予測候補・変換候補）が不整合になったときに、**永続データを壊さずに実行時状態だけ初期化する擬似的な再起動機能**を実装する。

## 方針

- 対象: 永続化されない実行時リソース（メモリ上の状態、ウィンドウ表示状態、一時キャッシュ、タイマー）
- 非対象: 学習データなどの永続データ
- メニューから明示的に実行できるようにする（例: `リセット`）
- 補足: 擬似再起動時に未確定の `composing` 内容が破棄されることは許容する（ユーザー復元が容易なため）

## リセット対象（永続化されないもの）

### 1. 変換セッション状態（SegmentsManager）

- `composingText`
- `rawCandidates`
- `selectionIndex`
- `didExperienceSegmentEdition`
- `lastOperation`
- `shouldShowCandidateWindow`
- `replaceSuggestions`
- `suggestSelectionIndex`

関連実装:
- `/Users/lpm11/Sources/azooKey-Desktop/Core/Sources/Core/InputUtils/SegmentsManager.swift:223`
- `/Users/lpm11/Sources/azooKey-Desktop/Core/Sources/Core/InputUtils/SegmentsManager.swift:576`
- `/Users/lpm11/Sources/azooKey-Desktop/Core/Sources/Core/InputUtils/SegmentsManager.swift:702`
- `/Users/lpm11/Sources/azooKey-Desktop/Core/Sources/Core/InputUtils/SegmentsManager.swift:708`

### 2. 候補ウィンドウ状態（変換候補）

- 候補ウィンドウの表示状態（表示/非表示）
- 候補ビューの候補配列・選択行
- ページング表示範囲（`showedRows`）

関連実装:
- `/Users/lpm11/Sources/azooKey-Desktop/azooKeyMac/InputController/azooKeyMacInputController.swift:791`
- `/Users/lpm11/Sources/azooKey-Desktop/azooKeyMac/InputController/CandidateWindow/BaseCandidateViewController.swift:133`
- `/Users/lpm11/Sources/azooKey-Desktop/azooKeyMac/InputController/CandidateWindow/CandidateView.swift:98`

### 3. 予測候補ウィンドウ状態

- `lastPredictionCandidates`
- `predictionSelectionIndex`
- `lastPredictionUpdateTime`
- `predictionHideWorkItem`（遅延非表示タスク）
- 予測ウィンドウの表示状態

関連実装:
- `/Users/lpm11/Sources/azooKey-Desktop/azooKeyMac/InputController/azooKeyMacInputController.swift:812`
- `/Users/lpm11/Sources/azooKey-Desktop/azooKeyMac/InputController/azooKeyMacInputController.swift:936`

### 4. 置換候補（Suggest）ウィンドウ状態

- 置換候補ウィンドウの表示状態
- 置換候補配列
- 置換候補の選択状態

関連実装:
- `/Users/lpm11/Sources/azooKey-Desktop/azooKeyMac/InputController/azooKeyMacInputController.swift:1107`
- `/Users/lpm11/Sources/azooKey-Desktop/azooKeyMac/InputController/azooKeyMacInputController.swift:1210`

### 5. 入力コントローラ一時状態

- `inputState`
- `markedTextReplacementRange`
- `isPromptWindowVisible`
- `retryCount`
- `lastKey`

関連実装:
- `/Users/lpm11/Sources/azooKey-Desktop/azooKeyMac/InputController/azooKeyMacInputController.swift:8`
- `/Users/lpm11/Sources/azooKey-Desktop/azooKeyMac/InputController/azooKeyMacInputController.swift:41`
- `/Users/lpm11/Sources/azooKey-Desktop/azooKeyMac/InputController/azooKeyMacInputController.swift:986`

### 6. プロンプト入力ウィンドウ一時状態

- プレビュー/適用/完了コールバック
- 初期プロンプト
- SwiftUI ビュー状態（再構築で初期化）

関連実装:
- `/Users/lpm11/Sources/azooKey-Desktop/azooKeyMac/Windows/PromptInput/PromptInputWindow.swift:82`
- `/Users/lpm11/Sources/azooKey-Desktop/azooKeyMac/Windows/PromptInput/PromptInputWindow.swift:133`

## 非対象（今回リセットしないもの）

- 学習データリセット（`resetMemory()`）
- 学習忘却（`forgetMemory()`）
- 永続設定（Config 値、ユーザー辞書ファイルなど）

## 実装上の注意

- 擬似再起動では、**永続化更新を伴う API を呼ばない**。
  - 例: `commitUpdateLearningData()` を内部で呼ぶ停止処理をそのまま使わない設計にする。
- 実行後は UI 側を確実に非表示・空表示へ同期する。
  - 候補ウィンドウ、予測ウィンドウ、置換候補ウィンドウ、プロンプト入力ウィンドウ
- 置換候補は `stopComposition()` だけでは消えないため、`setReplaceSuggestions([])` と `resetSuggestionSelection()` を必ず実行する。

## 非同期処理の無効化方針

- 擬似再起動時点で進行中の非同期処理結果を、その後の UI に反映させない。
- 対象:
  - `requestReplaceSuggestion()` から起動する候補取得 `Task`
  - `showPromptInputWindow()` のプレビュー取得 `Task`
- 実装方針:
  - 可能な `Task` はハンドルを保持して `cancel()` する。
  - 併せて controller に世代トークン（`restartEpoch`）を持ち、`Task` 開始時にスナップショットした epoch と完了時 epoch が一致しない場合は結果を破棄する。
  - `MainActor` で UI 更新する直前に epoch 一致を再確認する。

## 擬似再起動シーケンス（案）

1. `restartEpoch` をインクリメントし、進行中 `Task`（予測非表示、置換候補取得、プレビュー取得）を `cancel()` する。
2. 候補/予測/置換候補/プロンプト入力の各ウィンドウを閉じ、各ビューの候補配列と選択状態を空へ同期する。
3. `SegmentsManager` の変換中状態を初期化する。
4. 追加で `setReplaceSuggestions([])` と `resetSuggestionSelection()` を実行し、置換候補系の状態を明示的にクリアする。
5. `azooKeyMacInputController` の一時フラグを初期値へ戻す。
6. `refreshMarkedText()` / `refreshCandidateWindow()` / `refreshPredictionWindow()` を呼び、表示を同期する。
7. 実行結果をログに残す（デバッグ有効時）。

## 受け入れ条件（案）

- リセット実行直後に候補ウィンドウが残らない。
- リセット後に古い非同期結果でウィンドウが再表示されない。
- 次のキー入力で通常どおり候補生成が再開する。
- 実行前後で学習データが変化しない。
