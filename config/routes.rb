Rails.application.routes.draw do
  # Defines the root path route ("/")
  root "dashboards#show"

  # パスワードリセット (PasswordsController) はメール送信手段がないため持たない。
  # 忘れた場合は管理者が /admin/users から再設定する (docs/spec/05-auth.md)
  resource :session, only: %i[ new create destroy ]

  resource :menu, only: :show

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

  # マスタ。show は一覧で足りるので置かない。
  # 並べ替えは JS 無しで動く「上へ / 下へ」なので、position の更新も 1 つのリソースにする
  resources :categories, except: :show do
    resource :position, only: :update, module: :categories
  end
  resources :storage_locations, except: :show do
    resource :position, only: :update, module: :storage_locations
  end
  resources :stores, except: :show

  resource :account, only: %i[ show update ]
  namespace :account do
    resource :password, only: :update
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

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
end
