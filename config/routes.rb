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
  end

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
