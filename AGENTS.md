# azooKey-Desktop

## Overview
- Purpose: macOS向け日本語入力システム azooKey のデスクトップ実装。
- Main stack: Swift, Xcode project (`azooKeyMac.xcodeproj`), Swift Package (`Core/Package.swift`).
- Repo layout: `azooKeyMac/` (app), `Core/` (core package), `azooKeyMacTests/`, `azooKeyMacUITests/`, scripts (`install.sh`, `pkgbuild.sh`).

## Instructions
swift ソースに変更を加えた場合は、以下を実行して lint, test の通過を確認する。

- `swiftlint --fix --format`
- `swiftlint --quiet --strict`
- `swift test --package-path Core`
  - 依存パッケージでエラーが出ている場合は、`swift package --package-path Core reset` を実行すると直る場合がある
- `xcodebuild test -project azooKeyMac.xcodeproj -scheme azooKeyMac -destination 'platform=macOS'`
- `./install.sh --dry-run`
  - dry run によりビルドを実行することができる
