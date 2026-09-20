# Pin npm packages by running ./bin/importmap

pin "application"
# パスキーの base64url 変換 (登録用と認証用の 2 つの controller で共有する)。
# controllers/ の下に置くと eagerLoadControllersFrom の対象と紛らわしいので外に出す
pin "passkey_codec"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
