# つみくら

**家族でつなぐ、暮らしのストック**

家庭の消耗品 (トイレットペーパー、洗剤、電池、常備薬…) の在庫を家族で共有し、「そろそろ買う」を教えてくれる Web アプリ。名前は「積み倉」(家にあるストック) と「積み暮ら(し)」(日々の積み重ね) を重ねたもので、表示は常にひらがなで「つみくら」と書く。

> **現在の状態: [実装計画](docs/plan/implementation-plan.md) の全 13 フェーズを実装し、Dokku の本番環境で動かしている (2026-09-21 に初回デプロイ)。** 本番で確認できたのは、デプロイ一式 (Thruster、predeploy、HTTPS)、基本機能とブラウザ側の JavaScript、Android での通知、PC でのパスキー。まだ確認できていないのは、GitHub Actions (未 push。Chrome が要る system spec はそこで初めて走る)、毎朝の日次ダイジェスト、iPhone / iPad での通知とパスキー、使用履歴がたまってからの予測の表示。一覧は [未決事項と残作業](docs/plan/open-questions.md) を参照。 初回デプロイの後に、主キーを連番から UUIDv7 に変えた (URL では Base58 の 22 文字)。**この変更を本番に反映するには DB の作り直しが要る**。DB を作り直す前に push すると全画面が 500 になるので、必ず [デプロイの手順 10 節](docs/ops/deployment.md) の順に行うこと。

## 主な機能

- **ワンタップの使用記録** — スマホの一覧から「使った」を 1 タップ。使い始めた時点で在庫から引く
- **在庫切れ予測** — 実績の消費ペースから「次に使いたいときに在庫が無い日」を予測し、購入不要 / そろそろ購入 / 購入推奨の 3 段階で表示する。最低在庫数との悪い方を採用する
- **ロットと期限** — 購入 1 回 = 1 ロット。期限つきの品目は FEFO (期限が近い順) で自動引き当て、期限切れ・期限間近を知らせる
- **用途** — 「単 3 電池 / リモコン」のように用途別の交換履歴と交換周期を残す
- **買い物リスト** — 要購入の品目が自動で並び、チェックしてそのまま購入登録できる
- **棚卸** — 保管場所ごとに実数を数えて記録在庫を合わせる。マイナス差分は消費として予測に反映する
- **家族で共有** — 管理者が家族アカウントを発行。全記録に入力者が残る
- **PWA と Web Push** — ホーム画面に追加でき、状態が悪化した日の朝だけ 1 通通知する

## 技術スタック

Rails 8.1 / Ruby 4.0 / PostgreSQL / Solid Queue + Solid Cache (単一 DB) / Propshaft + importmap / Hotwire (Turbo + Stimulus) / Tailwind CSS / RSpec + FactoryBot / Dokku (Dockerfile デプロイ)

## ドキュメント

[docs/README.md](docs/README.md) に全文書の目次がある。

- [概要と確定要件](docs/spec/00-overview.md)
- [データモデル](docs/spec/01-domain-model.md) / [予測と要購入判定](docs/spec/02-forecast.md) / [画面](docs/spec/03-screens.md) / [通知と PWA](docs/spec/04-notifications.md) / [認証](docs/spec/05-auth.md)
- [デプロイ](docs/ops/deployment.md) / [開発環境](docs/ops/development.md)
- [実装計画](docs/plan/implementation-plan.md) / [未決事項](docs/plan/open-questions.md)

## 開発環境の最短手順

```bash
docker compose up -d --wait          # PostgreSQL
mise x -- bin/rails db:prepare
mise x -- bin/dev                    # http://localhost:3000
mise x -- bin/rspec                  # テスト
```

`compose.yaml` と `mise.toml` は Phase 1 で追加済み。詳細は [開発環境](docs/ops/development.md) を参照。

## ライセンス

[MIT License](LICENSE)
