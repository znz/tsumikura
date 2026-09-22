Rails.application.routes.draw do
  # Defines the root path route ("/")
  root "dashboards#show"

  # パスワードリセット (PasswordsController) はメール送信手段がないため持たない。
  # 忘れた場合は管理者が /admin/users から再設定する (docs/spec/05-auth.md)
  resource :session, only: %i[ new create destroy ]
  # パスキーでのログイン (docs/spec/05-auth.md 5 節)。**この 2 つだけが未ログインで叩ける。**
  # メールアドレスの入力なしでログインするので、URL に誰のものかは出ない
  namespace :sessions do
    resource :passkey, only: :create do
      post :options
    end
  end

  resource :menu, only: :show
  # 下部タブの中央「＋記録」。アクションシートは JS が要るのでページにする
  # (docs/spec/03-screens.md 1 節)
  resource :record_menu, only: :show, path: "record"

  # 品目は物理削除しない (docs/spec/01-domain-model.md 3 節) ので destroy を持たず、
  # アーカイブ / 復元を Items::ArchivesController に分ける
  resources :items, except: :destroy do
    resource :archive, only: %i[ create destroy ], module: :items
    # ワンタップ使用 (数量 1・今日・FEFO 自動)。品目の属性を触らないので
    # ItemsController には混ぜず、1 リソース = 1 コントローラに分ける
    resource :quick_use, only: :create, module: :items
    # 使用・購入の入力は品目配下
    resources :usage_records, only: %i[ new create ]
    resources :lots, only: %i[ new create ]
    resources :disposals, only: %i[ new create ]
    # 品目詳細の「最近の記録」(10 件) の続きを見る全履歴 (docs/spec/03-screens.md 画面 3b)。
    # 記録は 3 つのテーブル (使用・ロット・movement) に分かれていて 1 レコードを指せないので
    # index だけを置く
    resources :records, only: :index, module: :items
    # 用途マスタは品目詳細配下 (docs/spec/03-screens.md 画面 9b)。
    # as: :purposes で item_purposes_path(item) / edit_item_purpose_path(item, purpose) になる
    resources :item_purposes, path: "purposes", as: :purposes, except: :show do
      # 並べ替えとアーカイブは、position / archived_at を update で permit しないために分ける
      resource :position, only: :update, module: :item_purposes
      resource :archive, only: %i[ create destroy ], module: :item_purposes
    end
  end
  # 編集・削除は品目 id を URL に持たない (shallow)。
  # 使用記録・ロットの一覧・詳細は品目詳細が兼ねるので index / show は置かない
  resources :usage_records, only: %i[ edit update destroy ]
  resources :lots, only: %i[ edit update destroy ]
  # 廃棄は movement 1 行が記録そのものなので、取り消しは削除だけ
  resources :disposals, only: :destroy

  # 棚卸 (docs/spec/03-screens.md 画面 6)。下書きを作って数え、最後に確定する。
  # 確定は finalized_at を update で permit しないために別のコントローラに分ける
  resources :stock_takes do
    resource :finalization, only: :create, module: :stock_takes
  end

  # 買い物リスト (docs/spec/03-screens.md 画面 7)。
  # 一覧は「要購入判定からの導出 ∪ 永続行」なので、一覧そのものはリソースを持たない
  # (行の作成・更新・削除だけが shopping_list_items)
  resource :shopping_list, only: :show
  resources :shopping_list_items, only: %i[ create update destroy ]
  # まとめ購入。チェック済みの行から複数品目の Lot を 1 度に作る (画面 5b)
  resources :purchases, only: %i[ new create ]

  # マスタ。show は一覧で足りるので置かない。
  # 並べ替えは JS 無しで動く「上へ / 下へ」なので、position の更新も 1 つのリソースにする
  resources :categories, except: :show do
    resource :position, only: :update, module: :categories
  end
  resources :storage_locations, except: :show do
    resource :position, only: :update, module: :storage_locations
  end
  resources :stores, except: :show

  # Web Push の購読 (docs/spec/04-notifications.md 3 節)。
  # 登録は JS (push_subscription_controller.js) から JSON で、削除は画面のボタンからも行う
  resources :web_push_subscriptions, only: %i[ create destroy ]
  # テスト送信。購読の属性を変えないので web_push_subscriptions には混ぜない
  resource :notification_test, only: :create

  # パスキーの登録と削除 (docs/spec/05-auth.md 5 節)。
  # 一覧は /account のセクションが兼ねるので index は持たない
  resources :passkeys, only: %i[ create destroy ] do
    post :options, on: :collection
  end

  resource :account, only: %i[ show update ]
  namespace :account do
    resource :password, only: :update
    # 通知の種別 ON/OFF (JS 無しで動くフォーム)。
    # 表示名・メールの更新と permit する列を分けるためコントローラを分ける
    resource :notification_setting, only: :update
    # ログイン中デバイスの失効。ログアウト (SessionsController#destroy) と分けるため Account 名前空間に置く
    resources :sessions, only: :destroy do
      delete :others, on: :collection
    end
  end

  namespace :admin do
    resources :users, only: %i[ index new create edit update ] do
      resource :password_reset, only: %i[ new create ]
      resource :deactivation, only: %i[ create destroy ]
    end
  end

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # PWA の manifest と service worker (docs/spec/04-notifications.md 1 節)。
  # Rails::PwaController は ApplicationController を継承しないので認証を通らない。
  # manifest は「ホーム画面に追加」の前 (= 未ログインでも) 取得できる必要があるため、
  # これは仕様どおり (spec/requests/pwa_spec.rb で固定している)
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
end
