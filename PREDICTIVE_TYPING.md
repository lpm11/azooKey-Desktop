# 予測入力の調査メモ

## 結論（先に要点）
このリポジトリには、名前が近い「予測」機能が2系統あります。

1. **変換エンジン由来の予測候補（Prediction Window）**
- 変換中（`composing`）に表示される軽量な予測候補。
- `Tab` で受け入れ（末尾追加入力）する。
- 現状は **開発者向けトグル有効時のみ** 動作する。

2. **AIバックエンド由来の予測提案（Replace Suggestion Window）**
- `Ctrl-S`（`.suggest`）を起点に、AI（Foundation Models/OpenAI）へ問い合わせる提案機能。
- 未入力状態（`none`）では内部的に「`つづき`」を挿入して続き文候補を要求する。
- 変換中（`composing`）では現在の変換対象に対する置換候補を要求する。

---

## 1. 変換エンジン由来の予測候補（Prediction Window）

### 1-1. 有効化条件
- 設定は `Config.DebugPredictiveTyping`。
- デフォルトは `false`（無効）。
- 設定画面の開発者向け設定で `開発中の予測入力を有効化` をONにすると有効。

参照:
- `Core/Sources/Core/Configs/BoolConfigItem.swift:29`
- `Core/Sources/Core/Configs/BoolConfigItem.swift:30`
- `Core/Sources/Core/Configs/BoolConfigItem.swift:32`
- `azooKeyMac/Windows/ConfigWindow.swift:515`

### 1-2. 候補生成パイプライン
- Prediction Window の元データは `SegmentsManager.updateRawCandidate()` で毎回更新される `rawCandidates`。
- ここで `kanaKanjiConverter.requestCandidates(...)` を呼び、`ConversionResult.predictionResults` を受け取る。
- `requestCandidates` に渡している主入力は次の3つ。
  - `prefixComposingText`: 現在の変換対象（カーソル位置まで）
  - `leftSideContext`: 左文脈（最大30文字）
  - `options`: 予測有効/無効を含む変換オプション
- `DebugPredictiveTyping == true` のときだけ、
  - `requireJapanesePrediction: .manualMix`
  - `requireEnglishPrediction: .manualMix`
- 無効時は両方 `.disabled`。

参照:
- `Core/Sources/Core/InputUtils/SegmentsManager.swift:386`
- `Core/Sources/Core/InputUtils/SegmentsManager.swift:391`
- `Core/Sources/Core/InputUtils/SegmentsManager.swift:392`

### 1-3. `requestPredictionCandidates()` のロジック
`SegmentsManager.requestPredictionCandidates()` は次の条件で最大3件返します。

1. `DebugPredictiveTyping` がONであること
2. `convertTarget` が空でないこと
3. 末尾がASCII英字なら1文字落として照合（ローマ字入力途中を考慮）
4. 照合文字列長が2文字以上
5. `rawCandidates.predictionResults` を先頭から走査し、
   - 候補読み（`candidate.data[].ruby` 連結）をひらがな化
   - それが入力側プレフィックスと前方一致
   - かつ候補のほうが長い
6. 一致した候補について、差分だけ `appendText` を生成
7. 先頭から最大3件で打ち切る

補足:
- 順序は `rawCandidates.predictionResults` の先頭順を維持する。
- `appendText` は「いまの入力に追加で挿入する分」だけを持つ。
  例: 入力 `こんに` / 候補読み `こんにちは` のとき `appendText = "ちは"`。
- `displayText` は候補の表示文字列（`candidate.text`）で、挿入処理は `appendText` を使う。
- `Tab` 受け入れ時は `appendText` を `.direct` で挿入するだけで、AI再問い合わせは発生しない。
- つまり Prediction Window は「候補生成」と「受け入れ」の両方がローカル処理で完結する。

参照:
- `Core/Sources/Core/InputUtils/SegmentsManager.swift:47`
- `Core/Sources/Core/InputUtils/SegmentsManager.swift:52`
- `Core/Sources/Core/InputUtils/SegmentsManager.swift:589`
- `Core/Sources/Core/InputUtils/SegmentsManager.swift:600`
- `Core/Sources/Core/InputUtils/SegmentsManager.swift:604`
- `Core/Sources/Core/InputUtils/SegmentsManager.swift:613`
- `Core/Sources/Core/InputUtils/SegmentsManager.swift:629`

### 1-3-1. KanaKanjiConverter内部で何をしているか
`Prediction Window` に供給される `rawCandidates.predictionResults` は、`KanaKanjiConverter.requestCandidates(...)` の内部で次のように作られる。

1. `requestCandidates(inputData, options)` が入口
   - 空入力なら空結果を返す
   - 学習メモリ/辞書状態を更新
   - `convertToLattice(...)` でラティス計算
   - `processResult(...)` で `ConversionResult` へ整形

2. `processResult(...)` 内で予測候補を生成
   - 通常候補（全文候補）を作る
   - その中のベストな `CandidateData` を予測用起点として選ぶ
   - `getPredictionCandidate(...)` を呼んで予測候補列を作る
   - 重複除去して上位3件に絞る
   - `requireJapanesePrediction == .manualMix` のため `mainResults` には混ぜず `predictionResults` に分離

3. `getPredictionCandidate(...)` / `Kana2Kanji.getPredictionCandidates(...)` の中身
   - 末尾文節の読み（`lastRuby`）を取り出し、予測辞書（LOUDS）と動的ユーザ辞書をprefix一致で検索
   - 候補スコアを
     `lastCandidate.value + mmValue + ccValue + wValue + lengthPenalty - ignoreCCValue`
     で計算し、上位N件を維持
   - ここで
     - `mmValue`: 意味連接（前後の語のつながり）
     - `ccValue`: 品詞連接
     - `wValue`: 語そのものの重み
     - `lengthPenalty`: 読み長差のペナルティ

要点:
- 生成方式は「辞書 + 連接スコア + 学習辞書」ベース。

参照:
- `Core/.build/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModule/ConverterAPI/ConvertRequestOptions.swift:12`
- `Core/.build/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModule/ConverterAPI/KanaKanjiConverter.swift:323`
- `Core/.build/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModule/ConverterAPI/KanaKanjiConverter.swift:508`
- `Core/.build/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModule/ConverterAPI/KanaKanjiConverter.swift:575`
- `Core/.build/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModule/ConverterAPI/KanaKanjiConverter.swift:816`
- `Core/.build/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModule/ConversionAlgorithms/Prediction.swift:24`

### 1-4. 表示とウィンドウ挙動
- `handleClientAction(...)` の最後で常に `refreshPredictionWindow()` を呼ぶ。
- `inputState == .composing` のときだけ表示対象。その他状態では非表示。
- 候補が空でも、直前の候補を最大1秒キャッシュ表示するフェード的挙動あり。
- `up/down` で予測候補選択を開始した後は、タイムアウトによる自動クローズを行わない。
- ライブ変換OFFかつ通常候補ウィンドウ表示中は、予測ウィンドウを候補ウィンドウ右側へ配置。

参照:
- `azooKeyMac/InputController/azooKeyMacInputController.swift:504`
- `azooKeyMac/InputController/azooKeyMacInputController.swift:543`
- `azooKeyMac/InputController/azooKeyMacInputController.swift:553`
- `azooKeyMac/InputController/azooKeyMacInputController.swift:555`
- `azooKeyMac/InputController/azooKeyMacInputController.swift:585`
- `azooKeyMac/InputController/azooKeyMacInputController.swift:591`
- `azooKeyMac/InputController/azooKeyMacInputController.swift:624`
- `azooKeyMac/InputController/azooKeyMacInputController.swift:639`

UI補足:
- 予測候補ビューは先頭に矢印アイコンを付ける専用描画。
- 可視行数は最大3行（候補供給も最大3件）。

参照:
- `azooKeyMac/InputController/CandidateWindow/CandidateView.swift:84`
- `azooKeyMac/InputController/CandidateWindow/CandidateView.swift:89`

### 1-5. 候補選択・受け入れ操作
- `composing` かつ PredictionWindow 表示中では、`up/down` で予測候補を循環選択できる。
- `composing` 状態で `Tab` は `.acceptPredictionCandidate`。
- 実処理は `acceptPredictionCandidate()`:
  - 予測候補を取得し、選択中があればその候補、未選択なら先頭候補を採用
  - 入力末尾がASCII英字ならその1文字を削除
  - `appendText` を `.direct` でカーソル位置に挿入

参照:
- `Core/Sources/Core/InputUtils/InputState.swift:144`
- `Core/Sources/Core/InputUtils/Actions/ClientAction.swift:52`
- `azooKeyMac/InputController/azooKeyMacInputController.swift:432`
- `azooKeyMac/InputController/azooKeyMacInputController.swift:649`
- `azooKeyMac/InputController/azooKeyMacInputController.swift:658`
- `azooKeyMac/InputController/azooKeyMacInputController.swift:673`
- `KEYBINDINGS.md:22`

---

## 2. AIバックエンド由来の予測提案（Replace Suggestion）

### 2-1. 起点（Ctrl-S / メニュー）
- `Ctrl-S` は `.suggest`。
- 選択テキストあり: プロンプト入力ウィンドウ（変換）へ。
- 選択テキストなし:
  - `none` 状態: `.requestPredictiveSuggestion`（予測提案）
  - `composing` 状態: `.requestReplaceSuggestion`（置換提案）

参照:
- `KEYBINDINGS.md:40`
- `azooKeyMac/InputController/azooKeyMacInputController.swift:273`
- `Core/Sources/Core/InputUtils/InputState.swift:68`
- `Core/Sources/Core/InputUtils/InputState.swift:163`
- `azooKeyMac/InputController/azooKeyMacInputControllerHelper.swift:56`
- `azooKeyMac/InputController/azooKeyMacInputControllerHelper.swift:60`

### 2-2. `requestPredictiveSuggestion` の実体
- `ClientAction.requestPredictiveSuggestion` は、
  - まず `segmentsManager.insertAtCursorPosition("つづき", ...)`
  - 続いて `requestReplaceSuggestion()`
- つまり未入力状態の「予測提案」は、内部的には `<つづき>` ターゲットのAI提案に変換される。

参照:
- `Core/Sources/Core/InputUtils/Actions/ClientAction.swift:51`
- `azooKeyMac/InputController/azooKeyMacInputController.swift:428`
- `azooKeyMac/InputController/azooKeyMacInputController.swift:430`
- `azooKeyMac/InputController/azooKeyMacInputController.swift:431`

### 2-3. AI問い合わせ処理
`requestReplaceSuggestion()` は以下で候補を生成。

1. AIバックエンドが `off` なら何もしない
2. `prompt = 左文脈(max 100)` と `target = 現在のconvertTarget`
3. `OpenAIRequest(prompt,target,modelName)` を作成
4. `AIClient.sendRequest(...)` でバックエンド分岐
   - Foundation Models
   - OpenAI API
5. 返却文字列配列を `Candidate[]` に変換し、置換候補ウィンドウを表示

補足（Prediction Windowとの違い）:
- **生成モデル入力あり**。
- モデルへ渡す実入力は概ね `left context (max 100)` + `target(convertTarget)`。
- `requestPredictiveSuggestion`（未入力時の `Ctrl-S`）は、内部的に `target = "つづき"` を挿入してこの経路に流す。

参照:
- `azooKeyMac/InputController/azooKeyMacInputController.swift:793`
- `azooKeyMac/InputController/azooKeyMacInputController.swift:802`
- `azooKeyMac/InputController/azooKeyMacInputController.swift:813`
- `azooKeyMac/InputController/azooKeyMacInputController.swift:819`
- `azooKeyMac/InputController/azooKeyMacInputController.swift:840`
- `azooKeyMac/InputController/azooKeyMacInputController.swift:870`
- `Core/Sources/Core/MagicConversion/AIBackend.swift:21`
- `Core/Sources/Core/MagicConversion/AIBackend.swift:29`
- `Core/Sources/Core/MagicConversion/AIBackend.swift:31`

### 2-4. 「つづき」プロンプトの中身
- `Prompt.dictionary["つづき"]` が continuation 専用プロンプト。
- ここでは「2-5候補」を明示している。
- ただし共通追記（`sharedText`）では「3-5候補」を要求しており、指示が混在。

参照:
- `Core/Sources/Core/MagicConversion/OpenAIClient.swift:90`
- `Core/Sources/Core/MagicConversion/OpenAIClient.swift:92`
- `Core/Sources/Core/MagicConversion/OpenAIClient.swift:109`

### 2-5. バックエンド設定
- AIバックエンド設定は `AIBackendPreference`。
- 既定値は `off`（旧OpenAI設定のマイグレーション時のみ `openAI` になり得る）。
- UI上は `Off` / `Foundation Models` / `OpenAI API` を選択。

参照:
- `Core/Sources/Core/Configs/CustomCodableConfigItem.swift:206`
- `Core/Sources/Core/Configs/CustomCodableConfigItem.swift:215`
- `Core/Sources/Core/Configs/CustomCodableConfigItem.swift:222`
- `azooKeyMac/Windows/ConfigWindow.swift:236`
- `azooKeyMac/Windows/ConfigWindow.swift:240`
- `azooKeyMac/Windows/ConfigWindow.swift:243`

---

## 3. 使い分けまとめ

- **Prediction Window（変換エンジン）**
  - 条件: `DebugPredictiveTyping == true` かつ `composing`
  - 受け入れ: `Tab`
  - 生成モデル入力: **なし**（`KanaKanjiConverter.predictionResults` 由来）
  - 特徴: 低レイテンシ・ローカル変換候補依存

- **Replace Suggestion（AI提案）**
  - 条件: `AIBackendPreference != off`
  - 起点: `Ctrl-S`（またはメニュー「いい感じ変換」）
  - 生成モデル入力: **あり**（`prompt + target` を API/モデルに送信）
  - 特徴: 文脈ベースの生成候補、ネットワーク/モデル可用性に依存

---

## 4. 現状の制約・観察ポイント

- Prediction Windowは「開発中トグル」前提で、通常設定では無効。
- `つづき` プロンプトの候補数要求（2-5）と共通要求（3-5）が不整合。
- 命名上 `requestPredictiveSuggestion` が AI置換提案導線を含むため、Prediction Window 機能と混同しやすい。
