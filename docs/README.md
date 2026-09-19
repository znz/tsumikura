# つみくら ドキュメント

家庭用消耗品在庫管理 Web アプリ「つみくら」の仕様書と実装計画。まだ実装前で、この `docs/` が唯一の成果物である。

## 仕様

| 文書 | 内容 |
|---|---|
| [spec/00-overview.md](spec/00-overview.md) | 概要・名前の由来・スコープ・確定要件の一覧・用語・設計原則・将来の拡張候補 |
| [spec/01-domain-model.md](spec/01-domain-model.md) | 設計判断、テーブル定義、削除ルール、関連、サービスオブジェクト |
| [spec/02-forecast.md](spec/02-forecast.md) | 消費ペース、在庫切れ予測日、3 段階の要購入判定、期限判定、設定ファイル |
| [spec/03-screens.md](spec/03-screens.md) | ナビゲーション、画面一覧、ルーティング案 |
| [spec/04-notifications.md](spec/04-notifications.md) | PWA、Web Push、日次ダイジェスト |
| [spec/05-auth.md](spec/05-auth.md) | 認証、ユーザー管理、パスキー |

## 運用

| 文書 | 内容 |
|---|---|
| [ops/deployment.md](ops/deployment.md) | Dokku 構成 (単一 DB 化、`SOLID_QUEUE_IN_PUMA`、`app.json`、SSL、環境変数、バックアップ) |
| [ops/first-deploy.md](ops/first-deploy.md) | Phase 5 初回デプロイの実行手順書 (アプリ作成からバックアップ設定まで、上から順に実行する) |
| [ops/development.md](ops/development.md) | mise、Docker Compose、RSpec / FactoryBot、Tailwind、日本語化、CI |

## 計画

| 文書 | 内容 |
|---|---|
| [plan/implementation-plan.md](plan/implementation-plan.md) | 13 フェーズの実装計画。各フェーズのゴール・作業・TDD TODO・動作確認 |
| [plan/open-questions.md](plan/open-questions.md) | 未決事項 (推奨つき) と、決定済み事項とその理由 |

## 最初に読むとよい順番

1. [概要](spec/00-overview.md) — 何を作るのか
2. [予測と要購入判定](spec/02-forecast.md) — このアプリの心臓部
3. [データモデル](spec/01-domain-model.md) — 予測を支える台帳の構造
4. [実装計画](plan/implementation-plan.md) — どの順に作るか
