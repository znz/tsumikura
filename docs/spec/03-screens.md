# 画面とナビゲーション

[概要](00-overview.md) / [データモデル](01-domain-model.md) / [予測と要購入判定](02-forecast.md) / [認証](05-auth.md)

スマホ (縦持ち・片手操作) を基準に設計する。タップ領域は最低 44 × 44 px、主要な操作は画面下部に置く。

## 1. グローバルナビ (下部固定タブ・5 個)

```
[ホーム] [品目] [ ＋ ] [買い物] [メニュー]
                 ↑ 中央の大きい丸ボタン = 記録
```

- `env(safe-area-inset-bottom)` でホームインジケータを避ける。
- 中央の「＋」はアクションシートを開く: 使った / 買った / 棚卸 / 廃棄。
- 「メニュー」からマスタ管理・履歴・ユーザー管理・アカウント設定へ入る。

## 2. 画面一覧

| # | 画面 | パス | 主な要素 |
|---|---|---|---|
| 1 | ダッシュボード | `/` | (1) アラートカード 4 種 (購入推奨 n 件 / そろそろ n 件 / 期限切れ n 件 / 期限間近 n 件) (2) クイック使用 (`favorite` + 最近使った品目のタイル、タップで即記録) (3) 最近の記録 5 件 |
| 2 | 品目一覧 | `/items` | 検索 (名前・よみ)、カテゴリ / 保管場所 / 状態のフィルタチップ、行 = [名前 / 在庫 12 ロール / ステータスバッジ / 「使った」ボタン] |
| 3 | 品目詳細 | `/items/:id` | 在庫の大表示、予測 (在庫切れ予測日・ペース「約 2.3 個/月」・判定理由)、最低在庫、ロット一覧 (期限順・残数・期限バッジ)、用途一覧 (最終交換日・交換周期の中央値)、履歴タブ、操作ボタン群 |
| 4 | クイック使用記録 | `/items/:id/usage_records/new` (ボトムシート) | 数量 (既定 1・大きい +/− ボタン・`inputmode="numeric"`)、用途チップ (`tracks_purposes` のみ)、日付 (既定は今日・「昨日」ボタン・日付ピッカー。未来日は選べない)、ロット選択 (`tracks_expiry` のみ・既定は FEFO 自動) |
| 4b | ワンタップ使用 | `POST /items/:id/quick_use` | 数量 1・今日・FEFO で即記録。Turbo Stream でタイルと在庫を更新し、「取り消し」付きトーストを 8 秒表示 |
| 5 | 購入入力 | `/items/:id/lots/new` | 数量入力トグル (「入数 × パック数」/「直接入力」、入数は `default_pack_size` を初期値)、購入日、期限日 (`tracks_expiry` のみ)、税込合計金額、店舗セレクト |
| 5b | まとめ購入 | `/purchases/new` | 買い物リストのチェック済み行から複数品目を一括登録。店舗と購入日は共通、品目ごとに数量・金額 |
| 6 | 棚卸 | `/stock_takes/new` → `/stock_takes/:id/edit` | (1) 保管場所を選ぶ (2) その場所の品目リスト (記録在庫を薄く表示・実数を数値キーパッドで入力・未入力はスキップ) (3) 期限品でロットが複数なら「ロット別に数える」を展開 (4) 確認画面で差分サマリ (増 n 件 / 減 n 件) (5) 確定 |
| 7 | 買い物リスト | `/shopping_list` | 自動 (要購入) セクション + 手動追加セクション、チェックボックス、店舗でのグループ表示 (任意)、スヌーズ、自由入力の手動追加、「チェック済みを購入として記録」ボタン |
| 8 | 履歴 | `/history` | 全 `stock_movements` の時系列、種別・品目・記録者フィルタ、無限スクロール、各行から編集・削除 |
| 9 | マスタ | `/categories` `/storage_locations` `/stores` | 並べ替え可能な単純 CRUD。削除時は「n 件の品目から外れます」と確認 (nullify) |
| 9b | 用途マスタ | `/items/:id/purposes` | 品目詳細配下。名前・既定数量・並び順 |
| 10 | ユーザー管理 | `/admin/users` | 管理者のみ。一覧、追加 (名前 + メール + 初期パスワードを自動生成して画面表示)、役割変更、無効化、パスワード再設定 |
| 11 | アカウント設定 | `/account` | 表示名・メール変更、パスワード変更、パスキー一覧 / 追加 / 削除、プッシュ通知 ON/OFF + テスト送信、ログイン中セッション一覧 / 失効 |
| 12 | ログイン | `/session/new` | メールアドレス + パスワード、「パスキーでログイン」ボタン |

### 品目編集の予測設定

品目の編集画面 (`/items/:id/edit`) には、[予測](02-forecast.md) に効く設定をまとめて置く。

| 項目 | UI |
|---|---|
| 最低在庫数 | 数値入力 (空欄可)。「この数を切ったら購入推奨」と補足 |
| 予測モード | ラジオ: 自動 (`auto`) / 手動 (`manual`) / 予測しない (`none`) |
| 使用間隔 | `manual` のときだけ表示。「1 ロールを何日で使うか」の日数入力 (`manual_interval_days`) |
| そろそろ / 購入推奨の日数 | 空欄なら既定の 21 日 / 7 日 |
| 期限を管理する | チェックボックス (`tracks_expiry`)。ON のとき期限警告日数 (既定 30 日) を表示 |
| 用途を管理する | チェックボックス (`tracks_purposes`) |

### ステータスの見せ方

- バッジ: 購入推奨 (赤) / そろそろ購入 (黄) / 購入不要 (灰またはバッジなし) / `unknown` は「—」。
- 品目詳細では「在庫切れ予測日: 2026/10/07 (あと 18 日)」と日付と残り日数の両方を出し、「次に使いたいときに未使用在庫が無くなる日」である旨を補足に書く。
- `unknown` の品目には、品目詳細に「データ収集中 — 使用記録がたまると予測を開始します」と出し、不安にさせない。`none` モードの品目には「予測しない設定です」と出す。

## 3. ルーティング案

```ruby
Rails.application.routes.draw do
  root "dashboards#show"

  resource :session, only: %i[new create destroy]
  namespace :sessions do
    resource :passkey, only: :create do
      post :options                     # POST /sessions/passkey/options
    end
  end
  # パスワードリセットはメール送信手段がないため管理者操作のみ (PasswordsController は削除する)

  resources :items do
    post :quick_use, on: :member
    resources :usage_records, only: %i[new create], shallow: true
    resources :lots,          only: %i[new create], shallow: true
    resources :disposals,     only: %i[new create], shallow: true
    resources :item_purposes, path: "purposes", except: :show
  end
  resources :usage_records, only: %i[edit update destroy]
  resources :lots,          only: %i[show edit update destroy]
  resources :disposals,     only: :destroy

  resources :stock_takes do
    resource :finalization, only: :create, module: :stock_takes
  end

  resource  :shopping_list,       only: :show
  resources :shopping_list_items, only: %i[create update destroy]
  resources :purchases,           only: %i[new create]

  resources :stock_movements, only: :index, path: "history"
  resources :categories
  resources :storage_locations
  resources :stores

  resource  :account,  only: %i[show update]
  resources :passkeys, only: %i[index create destroy] do
    post :options, on: :collection
  end
  resources :web_push_subscriptions, only: %i[create destroy] do
    post :test, on: :collection
  end
  namespace :account do
    # ログイン中デバイスの失効。ログアウト (SessionsController#destroy) と分けるため Account::SessionsController にする
    resources :sessions, only: :destroy do
      delete :others, on: :collection   # このデバイス以外をログアウト
    end
  end

  namespace :admin do
    resources :users do
      resource :password_reset, only: %i[new create]
    end
  end

  get "manifest"       => "rails/pwa#manifest",       as: :pwa_manifest
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
  get "up"             => "rails/health#show",        as: :rails_health_check
end
```

## 4. 画面まわりの方針

- 画面の即時更新は Turbo Stream のレスポンスで行う。他のデバイスへのリアルタイム配信 (Action Cable のブロードキャスト) は行わない ([デプロイ](../ops/deployment.md) 参照)。
- 数値入力は `inputmode="numeric"` を付けてスマホのテンキーを出す。
- 破壊的操作 (記録の削除、マスタの削除) は確認ダイアログを出す。ワンタップ使用だけは確認せず、代わりに「取り消し」トーストを出す。
- 直近の棚卸日より前の日付で記録を作ろうとしたときは警告を出すが、保存はブロックしない。
