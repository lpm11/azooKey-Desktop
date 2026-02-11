# PERSONALIZATION

## 概要

azooKey Desktop における「パーソナライズ強度」は、Zenzai 変換時の**個人 LM 補正係数 (`alpha`)** に変換されて使われる。
この設定は「学習の ON/OFF」ではなく、**候補スコア再重み付けの強さ**に影響する。

## UI 設定値と内部 `alpha` の対応

- `off` -> `0.0`
- `soft` -> `0.5`
- `normal` -> `1.0`
- `hard` -> `1.5`

定義:
- `Core/Sources/Core/Configs/CustomCodableConfigItem.swift`
  - `Config.ZenzaiPersonalizationLevel.Value`
  - `alpha` 計算プロパティ
  - UserDefaults key: `dev.lpm11.inputmethod.azooKeyMac.preference.zenzai.personalization_level`

## パーソナライズ有効化条件

`SegmentsManager.getZenzaiPersonalizationMode()` で以下を満たしたときのみ有効:

1. `alpha > 0`（`off` ではない）
2. `containerURL` が取得できる
3. 個人 LM ファイル群が存在する
   - `Library/Application Support/p13n_v1/lm_c_abc.marisa`
   - `Library/Application Support/p13n_v1/lm_r_xbx.marisa`
   - `Library/Application Support/p13n_v1/lm_u_abx.marisa`
   - `Library/Application Support/p13n_v1/lm_u_xbc.marisa`

上記のどれかを満たさない場合、`personalizationMode` は `nil` となり、パーソナライズ補正は無効化される。

参照:
- `Core/Sources/Core/InputUtils/SegmentsManager.swift`

## 変換パイプラインでの使われ方

1. `SegmentsManager` が `ConvertRequestOptions.ZenzaiMode.on(...)` を構築
2. `personalizationMode` に `baseNgramLanguageModel`, `personalNgramLanguageModel`, `alpha` を渡す
3. `KanaKanjiConverter` 側で base/personal の EfficientNGram をロード
4. Zenz のトークンスコア算出で補正を適用

主要参照:
- `Core/Sources/Core/InputUtils/SegmentsManager.swift`
- `Core/.build/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModule/ConverterAPI/ConvertRequestOptions.swift`
- `Core/.build/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModule/ConverterAPI/KanaKanjiConverter.swift`
- `Core/.build/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModule/ConversionAlgorithms/Zenzai/Zenz/ZenzContext.swift`

## 実際の補正式

Zenz 内で、各トークンの対数確率 `logp` は次式で補正される:

`logp_ = logp + alpha * (lpp - lpb)`

- `lpb`: base LM の対数確率
- `lpp`: personal LM の対数確率
- `alpha`: パーソナライズ強度

`alpha` が大きいほど personal LM 側の傾向を強く反映する。

## 反映タイミング

- 設定 UI (`ConfigState`) は変更時に UserDefaults へ即保存する。
- ただし `SegmentsManager` の `zenzaiPersonalizationMode` は `activate()` で再計算される。
- そのため、入力セッション中の変更は次回アクティベート時に反映される設計。

参照:
- `azooKeyMac/Windows/ConfigState.swift`
- `Core/Sources/Core/InputUtils/SegmentsManager.swift`
- `azooKeyMac/InputController/azooKeyMacInputController.swift`

## 影響しないもの

この強度設定は、`KanaKanjiConverter.updateLearningData` / `commitUpdateLearningData` / `resetMemory` などの
学習メモリ更新 API の呼び出し条件そのものは変更しない。
主に「候補計算時の確率補正」に作用する。

参照:
- `Core/.build/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModule/ConverterAPI/KanaKanjiConverter.swift`
- `Core/Sources/Core/InputUtils/SegmentsManager.swift`

---

## 変換プロフィール

### 設定の実体

- 設定型: `Config.ZenzaiProfile`（`StringConfigItem`）
- 保存先: UserDefaults key `dev.lpm11.inputmethod.azooKeyMac.preference.ZenzaiProfile`
- 未設定時: 空文字列

参照:
- `Core/Sources/Core/Configs/StringConfigItem.swift`

### UI と反映

- UI には同じ設定への入力欄が2か所ある（基本タブ「変換設定」と詳細タブ「Zenzai設定」）。
- どちらも同一の `@ConfigState` バインディング (`$zenzaiProfile`) を使うため、実体は1つ。
- `@ConfigState` 経由で変更時に UserDefaults へ即保存される。

参照:
- `azooKeyMac/Windows/ConfigWindow.swift`
- `azooKeyMac/Windows/ConfigState.swift`

### 内部で効く場所

`SegmentsManager` は候補計算時に毎回 `ConvertRequestOptions` を作り、その中の
`zenzaiMode.versionDependentMode = .v3(.init(profile:leftSideContext:))` に
`Config.ZenzaiProfile().value` を渡す。

参照:
- `Core/Sources/Core/InputUtils/SegmentsManager.swift`

### プロンプトへの具体的注入方法（依存ライブラリ側）

Zenz v3 では、`profile` が空でない場合のみ有効。

- `profile.suffix(25)` で末尾25文字に切り詰め
- 特殊タグ `\u{EE03}` を付けて条件列に追加
- 最終プロンプトは概ね次の形:
  - 左文脈あり: `conditions + contextTag + leftSideContext + inputTag + input + outputTag`
  - 左文脈なし: `conditions + inputTag + input + outputTag`

また、左文脈自体は `SegmentsManager` 側で最大30文字程度にクリーニングされて渡される。

参照:
- `Core/.build/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModule/ConverterAPI/ConvertRequestOptions.swift`
- `Core/.build/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModule/ConversionAlgorithms/Zenzai/Zenz/ZenzContext.swift`
- `Core/Sources/Core/InputUtils/SegmentsManager.swift`

### 作用の要点

- 変換プロフィールは「候補評価時の条件付け（prompt conditioning）」に作用する。
- `Config.ZenzaiProfile().value` は候補更新のたびに読み直されるため、設定変更は次回候補計算から反映される。
- ただし、そもそも Zenzai モデルがロードできない場合は、Zenzai 経路自体が使われない。

参照:
- `Core/.build/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModule/ConverterAPI/KanaKanjiConverter.swift`

---

## 履歴学習

### 設定の実体

- 設定型: `Config.Learning`
- 値:
  - `inputAndOutput`（学習情報を使う + 更新する）
  - `onlyOutput`（学習情報を使う + 更新しない）
  - `nothing`（学習情報を使わない）
- UI ラベル:
  - 「学習する」=`inputAndOutput`
  - 「学習を停止」=`onlyOutput`
  - 「学習を無視」=`nothing`

参照:
- `Core/Sources/Core/Configs/CustomCodableConfigItem.swift`
- `azooKeyMac/Windows/ConfigWindow.swift`
- `Core/.build/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModule/DictionaryManagement/LearningType.swift`

### 変換処理への伝播

- `SegmentsManager` が `ConvertRequestOptions.learningType` に設定値を毎回渡す。
- `requestCandidates` 内で `updateIfRequired(options:)` が呼ばれ、`LearningConfig` が更新される。

参照:
- `Core/Sources/Core/InputUtils/SegmentsManager.swift`
- `Core/.build/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModule/ConverterAPI/KanaKanjiConverter.swift`
- `Core/.build/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModule/DictionaryManagement/DicdataStoreState.swift`

### 実際の分岐（use / update）

- 参照可否は `needUsingMemory`（`nothing` 以外で true）
- 更新可否は `needUpdateMemory`（`inputAndOutput` のみ true）

そのため:

1. `inputAndOutput`
   - 履歴メモリを候補生成に使用
   - 候補確定時に履歴を更新し、確定タイミングで永続化
2. `onlyOutput`
   - 履歴メモリを候補生成に使用
   - 更新はしない（`update` / `save` がガードでスキップ）
3. `nothing`
   - 履歴メモリを候補生成に使わない
   - 更新もしない

参照:
- `Core/.build/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModule/DictionaryManagement/LearningType.swift`
- `Core/.build/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModule/DictionaryManagement/LearningMemory.swift`
- `Core/.build/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModule/DictionaryManagement/DicdataStore.swift`

### 更新・永続化のトリガー

- 候補確定時: `prefixCandidateCommited` -> `updateLearningData(candidate)`
- 永続化: `commitUpdateLearningData()`
  - 入力終了 (`stopJapaneseInput`)
  - 入力システム非アクティブ化 (`deactivate`)

参照:
- `Core/Sources/Core/InputUtils/SegmentsManager.swift`
- `azooKeyMac/InputController/azooKeyMacInputController.swift`
- `Core/.build/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModule/ConverterAPI/KanaKanjiConverter.swift`

### 保存先とリセット

- 保存先ディレクトリ: `~/Library/Application Support/azooKey/memory`（実際は `applicationDirectoryURL`）
- 主なファイル: `memory.louds`, `memory.loudschars2`, `memory.memorymetadata`, `memory*.loudstxt3`
- UI の「履歴学習データをリセット」は `kanaKanjiConverter.resetMemory()` を呼び、上記学習ファイル群を削除する。

参照:
- `azooKeyMac/InputController/azooKeyMacInputController.swift`
- `Core/Sources/Core/InputUtils/SegmentsManager.swift`
- `azooKeyMac/Windows/ConfigWindow.swift`
- `Core/.build/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModule/DictionaryManagement/LearningMemory.swift`
