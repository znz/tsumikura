# 画面とナビゲーション

[概要](00-overview.md) / [データモデル](01-domain-model.md) / [予測と要購入判定](02-forecast.md) / [認証](05-auth.md)

スマホ (縦持ち・片手操作) を基準に設計する。タップ領域は最低 44 × 44 px、主要な操作は画面下部に置く。

## 1. グローバルナビ (下部固定タブ・5 個)

```
[ホーム] [品目] [ ＋ ] [買い物] [メニュー]
                 ↑ 中央の大きい丸ボタン = 記録
```

- `env(safe-area-inset-bottom)` でホームインジケータを避ける。
- 中央の「＋」は**記録メニューのページ** (`/record`) に送る: 使った / 買った / 棚卸 / 廃棄。
  アクションシート (ポップオーバー) は JS が要るので、メニュー (`/menu`) と同じくページにする
  (JS なしで動き、system spec も rack_test で回せる)。「使った」「買った」「廃棄」は品目を選んでから
  記録するので、品目一覧への導線にする。
- 「メニュー」からマスタ管理・履歴・ユーザー管理・アカウント設定へ入る。棚卸の一覧もここから開ける。

## 2. 画面一覧

| # | 画面 | パス | 主な要素 |
|---|---|---|---|
| 1 | ダッシュボード | `/` | (1) アラートカード 4 種 (購入推奨 n 件 / そろそろ n 件 / 期限切れ n 件 / 期限間近 n 件) (2) クイック使用 (`favorite` + 最近使った品目のタイル、タップで即記録) (3) 最近の記録 5 件 |
| 2 | 品目一覧 | `/items` | 検索 (名前・よみ)、カテゴリ / 保管場所 / 状態 (有効 / アーカイブ済み / すべて) の絞り込み、行 = [名前 / 在庫 12 ロール / ステータスバッジ / 「使った」ボタン]。絞り込みは JS 無しで動く GET フォーム (「絞り込む」ボタンで送信)。**`tracks_purposes` の品目の「使った」はワンタップにせず、用途を選べるフォーム (画面 4) へのリンクにする** (ワンタップだと用途が付かないため) |
| 3 | 品目詳細 | `/items/:id` | 在庫の大表示、「使った」/「使用を記録」/「購入を記録」/「廃棄を記録」、予測 (在庫切れ予測日・ペース「約 2.3 個/月」・判定理由)、最低在庫、ロット一覧 (期限順・残数・期限バッジ・購入日・店舗・単価。残 0 は畳む。平均単価。調整ロットには編集リンクを出さない。**期限切れロットには「廃棄」の導線**)、用途一覧 (最終交換日・交換周期の中央値。用途マスタへの導線)、最近の記録 (使用・購入・廃棄・棚卸の調整の時系列 10 件。使用は編集 / 削除、購入は編集、**廃棄は取り消し**、棚卸の調整は取り消せず棚卸へのリンクだけ)、操作ボタン群 (編集 / アーカイブ。**物理削除は提供しない**。アーカイブ済みならその旨と解除ボタン) |
| 4 | クイック使用記録 | `/items/:id/usage_records/new` | 数量 (既定 1・大きい +/− ボタン・`inputmode="numeric"`。用途を選ぶとその用途の既定数量になる)、用途チップ (`tracks_purposes` のみ。編集では、付いている用途がアーカイブ済みでも選択肢に残す)、日付 (既定は今日・「今日 / 昨日」ボタン・日付ピッカー。未来日は選べない)、ロット選択 (`tracks_expiry` のみ。新規は「自動 (期限が近い順)」、**編集は「変更しない (今のロットを優先)」が既定**)、メモ |
| 4b | ワンタップ使用 | `POST /items/:id/quick_use` | 数量 1・今日・FEFO で即記録。Turbo Stream で一覧の行と品目詳細の在庫を更新し、「取り消し」付きトーストを 8 秒表示 |
| 5 | 購入入力 | `/items/:id/lots/new` | 数量入力トグル (「入数 × パック数」/「直接入力」、入数は `default_pack_size` を初期値)、購入日 (既定は今日・未来日は不可)、期限日 (`tracks_expiry` のみ)、税込合計金額、店舗セレクト、メモ、種別 (購入 / 初期在庫) |
| 5b | まとめ購入 | `/purchases/new` | 買い物リストのチェック済み行から複数品目を一括登録。店舗と購入日は共通、品目ごとに数量・金額 |
| 6 | 棚卸 | `/stock_takes/new` → `/stock_takes/:id/edit` → `/stock_takes/:id` | (1) 保管場所と棚卸日を選ぶ (2) その場所の品目リスト (記録在庫を薄く表示・実数を数値キーパッドで入力・**未入力はスキップ**・「途中保存」で続きから数えられる) (3) 期限品でロットが複数なら「ロット別に数える」を `<details>` で展開 (入れると合計の入力は使わない。すでにロット別に数えたロットは、使い切られても欄を出し続け、開いた状態で描く) (4) 確認画面 (`show`) で差分サマリ (増 n 件 / 減 n 件) (5) 確定。確定済みの `show` は結果の表示だけで、編集・削除はできない (404)。**1 件も数えていなければ確定ボタンを出さない** |
| 6b | 棚卸一覧 | `/stock_takes` | 下書き (数えている途中) と確定済みを分けて並べる。下書きは入力画面へ、確定済みは結果へ |
| 6c | 廃棄 | `/items/:id/disposals/new` | 数量、理由 (期限切れ / 破損 / 紛失 / その他)、廃棄日 (未来日は不可)、ロット選択 (既定は「自動 (期限切れ → 期限が近い順)」)、メモ。品目詳細の期限切れロットの「廃棄」からはそのロットを選んだ状態で開く。記録すると「取り消し」付きトーストを出す |
| 6d | 記録メニュー | `/record` | 下部タブ中央の「＋記録」の実体。使った / 買った / 廃棄 は品目一覧へ、棚卸は新しい棚卸へ |
| 7 | 買い物リスト | `/shopping_list` | 自動 (要購入) セクション + 手動追加セクション、チェックボックス、店舗でのグループ表示 (任意)、スヌーズ、自由入力の手動追加、「チェック済みを購入として記録」ボタン |
| 8 | 履歴 | `/history` | 全 `stock_movements` の時系列、種別・品目・記録者フィルタ、無限スクロール、各行から編集・削除 |
| 9 | マスタ | `/categories` `/storage_locations` `/stores` | 並べ替え可能な単純 CRUD。並べ替えは JS 無しで動く「上へ / 下へ」ボタン (端では `disabled`)。削除は編集画面からで、そこに「n 件の品目から外れます」をサーバ側で出す (nullify)。`data-turbo-confirm` は補助に留める。店舗は `position` を持たないので名前順・並べ替えなし |
| 9b | 用途マスタ | `/items/:id/purposes` | 品目詳細配下。名前・既定数量・並び順 (「上へ / 下へ」は品目の中だけで動く)。使用記録がある用途は削除できないので**アーカイブ**で一覧から外す (編集画面の削除ボタンは `disabled` にして理由を出す) |
| 10 | ユーザー管理 | `/admin/users` | 管理者のみ。一覧、追加 (名前 + メール + 初期パスワードを自動生成して画面表示)、役割変更、無効化、パスワード再設定 |
| 11 | アカウント設定 | `/account` | 表示名・メール変更、パスワード変更、パスキー一覧 / 追加 / 削除、プッシュ通知 ON/OFF + テスト送信、ログイン中セッション一覧 / 失効 |
| 12 | ログイン | `/session/new` | メールアドレス + パスワード、「パスキーでログイン」ボタン。パスワード再設定のリンクは置かず「管理者に再設定してもらってください」と案内する |
| 13 | メニュー | `/menu` | 下部タブの「メニュー」の実体。アカウント設定 / ユーザー管理 (管理者のみ) / ログアウト / マスタ・履歴への入口。ポップオーバーではなくページにする (JS なしで動き、system spec も rack_test で回せる) |

### 品目編集の予測設定

品目の編集画面 (`/items/:id/edit`) には、[予測](02-forecast.md) に効く設定をまとめて置く。
スマホで邪魔にならないよう `<details>` に畳み、バリデーションエラーのときだけ開いた状態で描画する。
閾値は空欄なら既定値 (`config/tsumikura.yml`) を使う旨をプレースホルダと補足に出す。
予測モードが `manual` でも使用間隔は未入力のまま保存できる (予測が `unknown` になるだけ。[予測](02-forecast.md) 8 節)。

| 項目 | UI |
|---|---|
| 最低在庫数 | 数値入力 (空欄可)。「この数を切ったら購入推奨」と補足 |
| 予測モード | ラジオ: 自動 (`auto`) / 手動 (`manual`) / 予測しない (`none`) |
| 使用間隔 | 「1 ロールを何日で使うか」の日数入力 (`manual_interval_days`)。**`manual` のときは必須**。JS 無しで動かすため常時表示し、「手動のときだけ使います」と補足する (Stimulus での出し分けは後続のプログレッシブ強化) |
| そろそろ / 購入推奨の日数 | 空欄なら既定の 21 日 / 7 日。購入推奨は、そろそろ購入以下でなければならない (エラー文には両方の実効値を出す) |
| 期限を管理する | チェックボックス (`tracks_expiry`)。期限警告日数 (既定 30 日) も常時表示し、「期限を管理するときだけ使います」と補足する (出し分けは後続のプログレッシブ強化) |
| 用途を管理する | チェックボックス (`tracks_purposes`) |

### 使用記録 (JS が無くても動かす)

「使った」の周りはプログレッシブ強化にする。**JS が無くても記録・取り消しができる**ことを守る。

- **ワンタップ使用の応答**は 2 系統を同じ部分テンプレート (`layouts/_toast`) で作る。
  - Turbo Stream: 一覧の行 (`replace #item_<id>`) と品目詳細の本文 (`update #detail_item_<id>`) を
    描き直し、トーストを `#toasts` に `append` する。Turbo は画面に無い id を黙って無視するので、
    一覧からでも詳細からでも同じ応答で足りる。**フラッシュは残さない** (次の画面に持ち越さないため)。
  - HTML (JS 無し): 押した画面に戻し (`redirect_back_or_to`。外部サイトの Referer は無視して品目詳細へ)、
    `flash[:toast]` と `flash[:undo_path]` からレイアウトが同じトーストを描く。
    `undo_path` は「その記録を消す URL」なので、使用記録 (`DELETE /usage_records/:id`) と
    廃棄 (`DELETE /disposals/:id`) で同じ部分テンプレートを使い回せる。
- **取り消し**は、その使用記録を消す `DELETE /usage_records/:id` のボタン (`button_to`)。
  削除後は押した画面に戻す。ただし**削除した記録の編集画面には戻さない** (404 になるため品目詳細へ)。
- **トーストの 8 秒での自動消去だけ**が JS 必須 (`toast_controller.js`)。JS が無いときは消えないだけで、
  文言も取り消しボタンもそのまま使える (次の画面遷移で flash ごと消える)。
- 数量の「+ / −」(`quantity_stepper_controller.js`) と日付の「今日 / 昨日」
  (`date_shortcut_controller.js`) も同じ方針。ボタンは `hidden` で出しておき、Stimulus が付いたときだけ
  現れる。JS が無くても数値入力と日付ピッカーで記録できる。
- **用途の既定数量**も同じ形にする。JS があれば用途チップを選んだ時点で数量欄に
  `default_quantity` が入り、JS が無くても**数量を空で送れば**サーバ側が同じ値を補う
  (用途なしなら 1)。数量を書いていればそちらが優先。0 は入力の誤りとして 422 にする。
- 使用記録の**編集は movement を作り直す**ので、ロット選択の既定は「変更しない (今のロットを優先)」に
  する。選び直さない限り、いま引いているロットから引き直す (メモを直しただけでロット別の残数が
  変わらないようにするため)。
- ワンタップの「取り消し」は、既に取り消されていても 404 にせず
  「この使用の記録はすでに取り消されています。」と伝える (2 台で同時に押されることがある)。
- トーストには `data-turbo-temporary` を付ける (Turbo のスナップショットに残ると、「戻る」で
  復元された「取り消し」がもう無い記録を消そうとする)。読み上げ用の
  `role="status" aria-live="polite"` は、後から差し込まれるトーストではなく常設の `#toasts` に置く。
- **アーカイブ済みの品目には「使った」ボタンを出さない** (日々使う導線から外す)。
  サーバ側は記録を受け付けたままにする (アーカイブは一覧から外すだけの操作)。
- 在庫記録が足りずに補填したときは、トーストに
  「在庫記録が不足していたため n ロール を調整しました」を必ず添える (黙って在庫を作らない)。

### 購入入力の数量 (JS が無くても動かす)

「入数 × パック数」と「直接入力」の切り替えは**プログレッシブ強化**にする。

- サーバは常に 3 つの入力 (`pack_size` / `pack_count` / `initial_quantity`) を受け取り、
  **入数とパック数がそろっていればその積**、そうでなければ直接入力の数量を採る。
  使わなかった入数・パック数は「入力の記録」としても残さない (NULL にする)。
  ただし**検証エラーで再描画するときは入力を消さない** (消すのは保存の直前)。
- **編集では「書き換えたほう」を優先する**。JS があるときは隠れている側の入力欄が送られてこないので、
  「そろっていれば積」だけだと DB に残った入数 × パック数で数量を上書きしてしまう。
  入数かパック数が書き換えられていれば積、数量だけが書き換えられていれば直接入力を採り、
  どちらも変わっていなければ積のまま (何度保存しても変わらない)。
- JS が無いときは切り替えボタンを出さず、3 つの入力欄をすべて表示して
  「入数とパック数の両方を入れると掛け算になる」と補足する。
- JS があるときだけ Stimulus が切り替えボタンを表示し、使わない側の入力欄を
  `hidden` + `disabled` にして**送信しない**。
- 編集画面も同じフォームを使う。ただし種別 (購入 / 初期在庫) は作成時だけ選べる。

### 棚卸の入力 (JS が無くても動かす / 同時に数えても消えない)

- **入力欄には元の値を hidden (`counts[<品目 id>][was]`、ロット別は `counts[<品目 id>][lots_was][<ロット id>]`) で添え、サーバは「送られた値が元の値と違う欄」だけを書き換える。**
  フォームは全品目を送るので、そのまま書くと「A さんが品目 1〜5 を保存 → その前に画面を開いていた B さんが 6〜10 を入れて保存」で 1〜5 の明細が消えてしまう。値を消したとき (元の値あり → 空) だけ明細を削除し、同じ欄を 2 人が別の値にしたときは後勝ちにする。
- 画面に出ていない欄 (使い切られて消えたロットなど) は送られないので、触られない。
- **確認画面は「確定したらこうなる」値を出す。** 数えてから確定までに使用・購入があると、確定は確定時点の記録在庫との差を取るので、下書き時点の差分とは食い違う ([データモデル](01-domain-model.md) 判断 3)。確認画面では今の記録在庫で差分を計算し直し、数えたあとに在庫が動いた明細には「数えたあとに在庫の記録が動いています (10 → 9)。数えたあとに使った・買ったぶんなら数え直してください」と添える。差分サマリ (増 n 件 / 減 n 件) も同じ値で数える。
- **大きく減る差分には注意の印**を出す (記録在庫の半分以上かつ 2 以上の減少)。棚卸のマイナス差分は消費として予測に残り続けるので、打ち間違いはその場で気づきたい。

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

  # 品目は物理削除しないので destroy は持たない。
  # アーカイブ / 復元は archived_at を ItemsController#update で permit しないために分ける
  resources :items, except: :destroy do
    resource :archive, only: %i[create destroy], module: :items
    # ワンタップ使用。品目の属性を触らないので ItemsController には混ぜない
    resource :quick_use, only: :create, module: :items   # POST /items/:item_id/quick_use
    resources :usage_records, only: %i[new create], shallow: true
    resources :lots,          only: %i[new create], shallow: true
    resources :disposals,     only: %i[new create], shallow: true
    # as: :purposes で item_purposes_path(item) / edit_item_purpose_path(item, purpose) になる
    # (ネストの param は :purpose_id)
    resources :item_purposes, path: "purposes", as: :purposes, except: :show do
      # 並べ替えとアーカイブは、position / archived_at を update で permit しないために分ける
      resource :position, only: :update,            module: :item_purposes
      resource :archive,  only: %i[create destroy], module: :item_purposes
    end
  end
  resources :usage_records, only: %i[edit update destroy]
  # ロットの一覧・詳細は品目詳細が兼ねるので show は置かない
  resources :lots,          only: %i[edit update destroy]
  resources :disposals,     only: :destroy

  resources :stock_takes do
    resource :finalization, only: :create, module: :stock_takes
  end

  resource  :shopping_list,       only: :show
  resources :shopping_list_items, only: %i[create update destroy]
  resources :purchases,           only: %i[new create]

  resources :stock_movements, only: :index, path: "history"
  # マスタは一覧で足りるので show は置かない。
  # 並べ替え (上へ / 下へ) は position を update で permit しないために分ける
  resources :categories, except: :show do
    resource :position, only: :update, module: :categories
  end
  resources :storage_locations, except: :show do
    resource :position, only: :update, module: :storage_locations
  end
  resources :stores, except: :show

  resource  :menu,        only: :show       # 下部タブの「メニュー」
  resource  :record_menu, only: :show, path: "record"   # 下部タブ中央の「＋記録」
  resource  :account,  only: %i[show update]
  resources :passkeys, only: %i[index create destroy] do
    post :options, on: :collection
  end
  resources :web_push_subscriptions, only: %i[create destroy] do
    post :test, on: :collection
  end
  namespace :account do
    # パスワード変更は現在のパスワードの確認が要るので、プロフィール更新 (AccountsController#update) と分ける
    resource :password, only: :update
    # ログイン中デバイスの失効。ログアウト (SessionsController#destroy) と分けるため Account::SessionsController にする
    resources :sessions, only: :destroy do
      delete :others, on: :collection   # このデバイス以外をログアウト
    end
  end

  namespace :admin do
    # ユーザーは削除しないので destroy は持たない。show も一覧で足りるので置かない
    resources :users, only: %i[index new create edit update] do
      resource :password_reset, only: %i[new create]
      # 無効化 / 再有効化。role と deactivated_at を UsersController#update で permit しないために分ける
      resource :deactivation,   only: %i[create destroy]
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
- 直近の**確定済み**棚卸日より前の日付で記録を作ろうとしたときは警告を出すが、保存はブロックしない。
  警告は 2 か所に出す。**保存後の通知 (`notice` / トースト) に足す**のが本体で、JS 無しでも確実に出せる。
  加えて、使用記録・購入・廃棄のフォームの日付欄に「この品目を数えた直近の棚卸日は … です」を添えて、
  入力の時点でも気づけるようにする。判定は**品目単位** (`Item#last_counted_on`) で、
  その品目を実際に数えた確定済みの棚卸が無ければ何も出さない
  (冷蔵庫を数えただけで洗剤の記録にまで警告が出ると読まれなくなる)。
