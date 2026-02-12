# azooKey-Desktop Keybindings

`Core/Sources/Core/InputUtils/Actions/UserAction.swift` を起点に、`InputState` と `ClientAction` まで追跡した対応表です。
同じキーでも入力状態で動作が変わるため、「発生する事象」は状態依存で記載しています。

## 状態の略語

- `none`: 未変換（通常入力）
- `composing`: 変換中
- `previewing`: 先頭候補プレビュー中
- `selecting`: 候補選択中
- `replaceSuggestion`: 置換候補選択中
- `unicodeInput`: Unicode 入力モード
- `attachDiacritic`: 英語 dead key 合成待ち

## 主要キーバインド

| キー                                | 内部アクション              | 発生する事象（ユーザー視点）                                                                                                                                                                                                 | 主な条件                                         |
| ----------------------------------- | --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------ |
| `Enter` / `Numpad Enter` / `Ctrl-M` | `.enter`                    | `composing`/`previewing`: **確定**。`selecting`: **選択候補を確定**。`replaceSuggestion`: **置換候補を適用**。`unicodeInput`: **Unicodeコードを確定して1文字入力**。                                                         | 状態依存                                         |
| `Space`                             | `.space(...)`               | `none`: 半角/全角スペース入力。`composing`: 候補表示（ライブ変換 ON: `selecting`、OFF: `previewing`）。`selecting`: 次候補（`Shift` 付きは前候補）。`replaceSuggestion`: 次置換候補。`unicodeInput`: コード確定/キャンセル。 | `TypeHalfSpace` 設定と `Shift` で半角/全角が切替 |
| `Tab`                               | `.tab`                      | `composing`: **予測候補を受け入れ**（Prediction選択中は選択中候補）。`attachDiacritic`: dead key + タブを挿入。                                                                                                              | 状態依存                                         |
| `Delete` / `Ctrl-H`                 | `.backspace`                | 1文字削除。`composing`/`previewing`/`selecting`/`unicodeInput` でそれぞれ削除処理。`unicodeInput` で空ならキャンセル。                                                                                                       | 状態依存                                         |
| `Ctrl-Delete`                       | `.forget`                   | **学習内容をリセット**。                                                                                                                                                                                                     | 主に `selecting` で有効                          |
| `Escape`                            | `.escape`                   | 変換/候補選択/Unicode入力のキャンセル、候補ウィンドウを閉じる。                                                                                                                                                              | 状態依存                                         |
| `↑` / `Ctrl-P`                      | `.navigation(.up)`          | PredictionWindow 表示中の `composing`: **予測候補を上方向に選択**。`selecting`: 前候補へ。                                                                                                                                  | 状態依存                                         |
| `↓` / `Ctrl-N`                      | `.navigation(.down)`        | PredictionWindow 表示中の `composing`: **予測候補を下方向に選択**。それ以外の `composing`/`previewing`: 候補選択開始。`selecting`: 次候補へ。                                                                                | 状態依存                                         |
| `PageUp`                            | `.navigation(.pageUp)`      | `selecting`: **候補を1ページ前へ移動**（先頭ページなら末尾ページへラップ）。                                                                                                                                                 | 状態依存                                         |
| `PageDown`                          | `.navigation(.pageDown)`    | `selecting`: **候補を1ページ次へ移動**（末尾ページなら先頭ページへラップ）。                                                                                                                                                 | 状態依存                                         |
| `Home`                              | `.navigation(.home)`        | `selecting`: **先頭候補へ移動**。                                                                                                                                                                                             | 状態依存                                         |
| `End`                               | `.navigation(.end)`         | `selecting`: **末尾候補へ移動**。                                                                                                                                                                                             | 状態依存                                         |
| `→` / `Ctrl-F`                      | `.navigation(.right)`       | `selecting`: 候補確定（または文節移動）。                                                                                                                                                                                    | `Shift` 併用で文節編集                           |
| `Shift+←` / `Shift+→`               | `.navigation(.left/.right)` | **文節編集（セグメント移動）**。                                                                                                                                                                                             | `composing`/`previewing`/`selecting`             |
| `Ctrl-I` / `Ctrl-O`                 | `.editSegment(-1/+1)`       | **文節編集（左/右）**。                                                                                                                                                                                                      | `selecting` に遷移                               |
| `F6` / `Ctrl-J`                     | `.function(.six)`           | **ひらがな変換で確定**。                                                                                                                                                                                                     | 変換系状態で有効                                 |
| `F7` / `Ctrl-K`                     | `.function(.seven)`         | **カタカナ変換で確定**。                                                                                                                                                                                                     | 同上                                             |
| `F8` / `Ctrl-;`                     | `.function(.eight)`         | **半角カタカナ変換で確定**。                                                                                                                                                                                                 | 同上                                             |
| `F9` / `Ctrl-L`                     | `.function(.nine)`          | **全角英数変換で確定**。                                                                                                                                                                                                     | 同上                                             |
| `F10` / `Ctrl-:` / `Ctrl-'`         | `.function(.ten)`           | **半角英数変換で確定**。                                                                                                                                                                                                     | 同上                                             |
| `1`-`9`                             | `.number(.one ... .nine)`   | `selecting`: **番号候補を選択して確定**。その他: 数字入力。                                                                                                                                                                  | 状態依存                                         |
| `0` / `Shift+0`(JIS)                | `.number(.zero/.shiftZero)` | `selecting`: 候補番号選択には使わず **`0` 入力として確定+継続**。                                                                                                                                                            | JIS `Shift+0` は専用処理                         |
| `英数` キー                         | `.英数`                     | **英数入力へ切替**。                                                                                                                                                                                                         | `selecting` では確定後に切替                     |
| `かな` キー                         | `.かな`                     | **かな入力へ切替**。                                                                                                                                                                                                         | 状態依存                                         |
| `Ctrl-S`                            | `.suggest`                  | **提案機能**。選択テキストあり + AI有効: プロンプト入力ウィンドウ表示。変換中: 置換候補要求。未入力: 予測提案要求。                                                                                                          | AI backend 有効時                                |
| `Ctrl-Shift-R`                      | `.reconvertCommittedText`   | **確定文字列を再変換**。選択範囲があれば選択文字列を再変換、なければ直前確定の取り消し・再変換を試行。                                                                                                                       | 状態依存。条件不一致時は no-op                   |
| `Ctrl-Shift-U`                      | `.startUnicodeInput`        | **Unicode 入力モード開始**。                                                                                                                                                                                                 | 状態により先に確定してから遷移                   |

## 記号・特殊入力

| キー                                           | 内部アクション                        | 発生する事象（ユーザー視点）               | 条件                             |
| ---------------------------------------------- | ------------------------------------- | ------------------------------------------ | -------------------------------- |
| `Option` + dead key（`¨` `´` `grave` `ˆ` `˜`） | `.deadKey(...)`                       | 次の文字と合成してアクセント付き文字入力。 | 英語入力時                       |
| `Shift+¥` / `Shift+\`（`Option` 併用含む）     | `.input("\|")`                        | `\|` 入力。                                | -                                |
| `¥` / `\`                                      | `.input(...)`                         | `¥` または `\` を入力。                    | `TypeBackSlash` 設定で出力を切替 |
| `Option+¥` / `Option+\`                        | `.input(...)`                         | `¥` と `\` を通常時と逆側で入力。          | `TypeBackSlash` 設定依存         |
| `Shift+/`                                      | `.input("?")`                         | `?` 入力。                                 | 日本語入力時                     |
| `Shift+Option+/`                               | `.input("…")`                         | `…` 入力。                                 | 日本語入力時                     |
| `Option+/`                                     | `.input("／")`                        | 全角スラッシュ入力。                       | 日本語入力時                     |
| `Option+[` / `Option+]`                        | `.input("［" / "］")`                 | 全角角括弧入力。                           | 日本語入力時                     |
| `Shift+Option+[` / `Shift+Option+]`            | `.input("｛" / "｝")`                 | 全角波括弧入力。                           | 日本語入力時                     |
| `Option+,` / `Option+.`                        | `.input(... invertPunctuation: true)` | 句読点スタイルを反転した記号入力。         | 日本語入力時                     |
| `Numpad /` `,` `.`                             | `.input("/")` など                    | 対応記号を直接入力。                       | -                                |

## 補足

- `Command` を含むキーは IME 側で処理せず、基本的にアプリへフォールスルーします。
- `Option` を含むキーは、`input`/`deadKey`/`backspace` 以外は多くがフォールスルーします。
- Numpad の一部キー（順方向削除、全消し相当）は明示的に `unknown` として無効化されています。
- `英数` ダブルタップは、選択テキストがあれば英訳トリガー、変換中テキストがあれば半角英数化して英数入力へ切替します。
- `かな` ダブルタップは、`AZOOKEY_ENABLE_KANA_DOUBLE_TAP_RECONVERT` が有効なら再変換トリガー、無効なら選択テキストの和訳トリガーです（`azooKeyMacInputController` 側処理）。

## 参照

- `Core/Sources/Core/InputUtils/Actions/UserAction.swift`
- `Core/Sources/Core/InputUtils/InputState.swift`
- `Core/Sources/Core/InputUtils/Actions/ClientAction.swift`
- `azooKeyMac/InputController/azooKeyMacInputController.swift`
- `Core/Sources/Core/InputUtils/DiacriticAttacher.swift`
