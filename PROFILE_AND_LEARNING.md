# PROFILE_AND_LEARNING

## 対象

このドキュメントは、azooKey Desktop における以下 2 つの個人特化機能の実装上の挙動をまとめたものです。

- 変換プロフィール
- 履歴学習

注: 解説中の Bundle ID は `{bundle ID}` と表記します。

## 1. 変換プロフィール

### 設定の実体

- 設定型: `Config.ZenzaiProfile`
- 保存先キー: `...preference.ZenzaiProfile`（UserDefaults）
- 値型: `String`（未設定時は空文字）

### UI

- `ConfigWindow` の「変換設定」と「詳細設定」に同じ入力欄がある。
- どちらも同じ `@ConfigState`（`$zenzaiProfile`）にバインドされるため、実体は 1 つ。
- 入力変更時に即時保存される。

### 変換処理への伝播

`SegmentsManager` は候補計算時に毎回 `ConvertRequestOptions` を組み立て、`Zenzai` の v3 設定へ `profile` を渡す。

- 渡し先: `zenzaiMode.versionDependentMode = .v3(.init(profile:leftSideContext:))`
- 候補計算: `requestCandidates(... options: ...)` 経路で使用

### 実際の効き方（依存ライブラリ側）

Zenz v3 の評価処理では、`profile` が空でない場合のみ条件としてプロンプトに追加される。

- 長さ制限: `profile.suffix(25)`
- 付与タグ: `\u{EE03}`
- 概念的には「候補評価プロンプトの条件付け」に作用

要するに、プロフィールは学習データを書き換える機能ではなく、推論時の条件付けです。

## 2. 履歴学習

### 設定の実体

- 設定型: `Config.Learning`
- UI と内部値の対応:
  - `学習する` -> `inputAndOutput`
  - `学習を停止` -> `onlyOutput`
  - `学習を無視` -> `nothing`

### 変換処理への伝播

`SegmentsManager` が候補計算時に `ConvertRequestOptions.learningType` へ反映し、Converter 側で `LearningConfig` として評価される。

### 実際の分岐（use/update）

依存ライブラリの `LearningType` は以下の 2 軸で分岐する。

- `needUsingMemory`: `nothing` 以外で true
- `needUpdateMemory`: `inputAndOutput` のみ true

そのため:

1. `inputAndOutput`
- 履歴を候補生成に使う
- 確定時に履歴を更新する

2. `onlyOutput`
- 履歴を候補生成に使う
- 更新はしない

3. `nothing`
- 履歴を候補生成に使わない
- 更新もしない

### 更新・永続化タイミング

- 候補確定時: `updateLearningData(candidate)` が呼ばれる
- 永続化: `commitUpdateLearningData()` が呼ばれたタイミング
  - 日本語入力終了時 (`stopJapaneseInput`)
  - IME 非アクティブ化時 (`deactivate`)

### リセット

設定画面の「履歴学習データをリセット」は `kanaKanjiConverter.resetMemory()` を呼ぶ。
これにより学習メモリファイル群（`memory.*`）が削除される。

## 3. 実ファイルの保存先（実機確認ベース）

`~/Library/Application Support/azooKey/memory` ではなく、コンテナ内に保存される。

- `~/Library/Containers/{bundle ID}/Data/Library/Application Support/azooKey/memory`

また個人 LM（パーソナライズ強度で参照する `lm_*.marisa`）は別系統で、通常は App Group 側を参照する。

- `~/Library/Group Containers/group.{bundle ID}/Library/Application Support/p13n_v1`

## 4. 参照コード

- `Core/Sources/Core/Configs/StringConfigItem.swift`
- `Core/Sources/Core/Configs/CustomCodableConfigItem.swift`
- `Core/Sources/Core/InputUtils/SegmentsManager.swift`
- `azooKeyMac/Windows/ConfigWindow.swift`
- `azooKeyMac/Windows/ConfigState.swift`
- `azooKeyMac/InputController/azooKeyMacInputController.swift`
- `Core/.build/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModule/ConverterAPI/ConvertRequestOptions.swift`
- `Core/.build/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModule/ConverterAPI/KanaKanjiConverter.swift`
- `Core/.build/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModule/DictionaryManagement/LearningType.swift`
- `Core/.build/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModule/DictionaryManagement/DicdataStoreState.swift`
- `Core/.build/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModule/DictionaryManagement/LearningMemory.swift`
- `Core/.build/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModule/DictionaryManagement/DicdataStore.swift`
- `Core/.build/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModule/ConversionAlgorithms/Zenzai/Zenz/ZenzContext.swift`
