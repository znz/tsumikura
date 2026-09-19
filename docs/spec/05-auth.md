# 認証とユーザー管理

[概要](00-overview.md) / [データモデル](01-domain-model.md) / [画面](03-screens.md) / [デプロイ](../ops/deployment.md)

## 1. 基本方針

- Rails 8 標準の認証ジェネレータ (`bin/rails generate authentication`) をベースにする。生成物は `User` / `Session` / `Current` / `Authentication` concern / `SessionsController` / `PasswordsController` / `PasswordsMailer`。
- **ログイン ID はメールアドレス** (`users.email_address`) とする。生成物の既定をそのまま使う。メールは**送らない**ので、実在のアドレスである必要はない (家族内で分かる文字列であればよい) が、ID として一意である必要はある。
- **メール送信機能は持たない。** `PasswordsController` と `PasswordsMailer` および関連ビュー・ルートは削除する。パスワードを忘れた場合は**管理者が再設定**する。
- **パスワードは常に必須**。パスキーは追加の認証手段として位置づける。デバイス紛失時に管理者がリセットできる退路を必ず残す。
- 公開サインアップは無い。`/sign_up` に相当する画面を作らない。

## 2. ユーザーの種類

| 役割 | `role` | できること |
|---|---|---|
| 一般 (member) | 0 | 在庫・記録・買い物リストの全操作、マスタの編集、自分のアカウント設定 |
| 管理者 (admin) | 1 | 上記に加えて、ユーザーの追加・役割変更・無効化・パスワード再設定 |

- 家庭内なので在庫データに対する権限差は設けない。差があるのは**ユーザー管理だけ**。
- ユーザーは**削除しない**。`deactivated_at` を打って無効化する (記録の入力者としての参照が残るため)。無効化されたユーザーはログインできず、既存セッションも失効させる。

### 最後の管理者の保護

- 有効な管理者が 1 人だけのとき、その管理者の **role 降格**と**無効化**をバリデーションで禁止する (自分自身の操作でも他人の操作でも同じ)。
- 誰もログインできなくなった場合の復旧手段として、サーバ上で `tsumikura:create_admin` を実行できるようにする ([デプロイ](../ops/deployment.md))。

## 3. 初期セットアップとユーザー追加

```bash
# 最初の管理者 (デプロイ直後に 1 回)
bin/rails tsumikura:create_admin ADMIN_EMAIL=admin@example.com ADMIN_NAME=かんりしゃ
```

- タスクは**冪等**にする。同じメールアドレスで 2 回実行してもユーザーは重複せず、role を admin に揃えるだけにする。
- パスワードは自動生成して標準出力に 1 度だけ表示する (`ADMIN_PASSWORD` 環境変数で指定も可)。
- `db/seeds.rb` は ENV なしでも成功する冪等な実装にする (CI の `db:seed:replant` を通すため)。管理者作成は seeds ではなく rake タスクに置く。

以降の家族アカウントは管理者が `/admin/users` から追加する。

| 操作 | 挙動 |
|---|---|
| 追加 | 名前 + メールアドレスを入力。初期パスワードを自動生成し、**作成直後の画面に 1 度だけ表示**する (再表示はできない) |
| 役割変更 | member <-> admin。最後の管理者は降格できない |
| 無効化 / 再有効化 | `deactivated_at` の設定・解除。最後の管理者は無効化できない |
| パスワード再設定 | 管理者が新しいパスワードを生成し、画面に 1 度だけ表示する (`Admin::PasswordResetsController`)。本人のセッションはすべて失効させる |

## 4. セッション

- Rails 生成のとおり `cookies.signed.permanent` を使う (実質的に長期間ログインしたまま)。家庭用でスマホから頻繁に再ログインさせたくないため。
- 代わりに `/account` に**ログイン中のデバイス一覧**を置き、`sessions` の `ip_address` / `user_agent` / ログイン日時 (`created_at`) を表示して個別に失効できるようにする。「このデバイス以外をログアウト」も置く (`Account::SessionsController`)。
- ログインの試行には `rate_limit to: 10, within: 3.minutes` を掛ける (認証ジェネレータの生成物に含まれる。生成結果を確認してそのまま使う)。
- 無効化 (`deactivated_at`) されたユーザーは、パスワードが正しくてもログインできない。セッションの復元時 (`resume_session`) にも無効化を確認し、無効化と同時にそのユーザーの `sessions` を全削除する。

## 5. パスキー (WebAuthn)

### 方針

- `webauthn` gem を使う。登録は discoverable credential (resident key) にして、**ユーザー名の入力なしでログイン**できるようにする (スマホ中心の UX に効く)。
- パスキーは追加手段であり、パスワードを無効化することはできない。
- パスキーを 1 つも持たないユーザーも普通に使える。

### 設定

`config/initializers/webauthn.rb`:

```ruby
WebAuthn.configure do |config|
  # webauthn gem のバージョンによっては config.origin = "..." (単数)。Phase 13 で導入するバージョンの README を確認する
  config.allowed_origins = [ ENV.fetch("WEBAUTHN_ORIGIN", "http://localhost:3000") ]
  config.rp_name = "つみくら"
  config.rp_id   = ENV["WEBAUTHN_RP_ID"]   # 未設定なら origin から導出される
  config.credential_options_timeout = 120_000
end
```

| 環境変数 | 値の例 | 備考 |
|---|---|---|
| `WEBAUTHN_ORIGIN` | `https://tsumikura.example.com` | スキーム + ホスト + (非標準ポート) |
| `WEBAUTHN_RP_ID` | `tsumikura.example.com` | **ホスト名のみ**。スキーム・ポート・パスを含めない |

開発環境は `http://localhost:3000` / `localhost` (localhost は Secure Context 扱いなので HTTPS 不要)。

### 登録フロー

```
1. GET  /passkeys                     一覧 + 「このデバイスを登録」
2. POST /passkeys/options             サーバ:
     user.webauthn_id ||= WebAuthn.generate_user_id
     options = WebAuthn::Credential.options_for_create(
       user: { id: user.webauthn_id, name: user.email_address, display_name: user.name },
       exclude: user.passkeys.pluck(:external_id),
       authenticator_selection: { resident_key: "required", user_verification: "preferred" }
     )
     session[:webauthn_challenge] = options.challenge
     render json: options
3. JS   navigator.credentials.create({ publicKey: options })
4. POST /passkeys   { credential: <JSON>, nickname: "太郎のiPhone" }
     webauthn_credential = WebAuthn::Credential.from_create(JSON.parse(params[:credential]))
     webauthn_credential.verify(session.delete(:webauthn_challenge))
     user.passkeys.create!(
       external_id: webauthn_credential.id,
       public_key:  webauthn_credential.public_key,
       sign_count:  webauthn_credential.sign_count,
       nickname:    params[:nickname]
     )
```

### 認証フロー (usernameless)

```
1. POST /sessions/passkey/options     (allow_unauthenticated_access)
     options = WebAuthn::Credential.options_for_get(user_verification: "preferred")
     # allow_credentials を渡さない = discoverable credential を使う
     session[:webauthn_challenge] = options.challenge
2. JS   navigator.credentials.get({ publicKey: options, mediation: "conditional" })
        # conditional UI でメール欄にパスキー候補を出すと 1 タップになる
3. POST /sessions/passkey  { credential: <JSON> }
     webauthn_credential = WebAuthn::Credential.from_get(JSON.parse(params[:credential]))
     passkey = Passkey.find_by!(external_id: webauthn_credential.id)
     webauthn_credential.verify(
       session.delete(:webauthn_challenge),
       public_key: passkey.public_key,
       sign_count: passkey.sign_count
     )
     passkey.update!(sign_count: webauthn_credential.sign_count, last_used_at: Time.current)
     start_new_session_for(passkey.user)     # Authentication concern の private メソッド
```

- `SessionsController#create` と同様に `rate_limit to: 10, within: 3.minutes` を適用する。
- 無効化されたユーザーのパスキーではログインできないようにする。

> 同期型のパスキー (iCloud キーチェーン、Google パスワードマネージャー) は `sign_count` を常に 0 で返すことが多い。WebAuthn の仕様上、保存値も受信値も 0 の場合はカウンタ検証の対象外なので、そのまま動く。

### テスト方法

```ruby
# spec/support/webauthn_helper.rb
require "webauthn/fake_client"

module WebauthnHelper
  def fake_client(origin = "http://www.example.com")
    @fake_client ||= WebAuthn::FakeClient.new(origin)
  end

  def register_passkey_for(user, nickname: "test device")
    sign_in user
    post options_passkeys_path
    challenge = response.parsed_body["challenge"]
    credential = fake_client.create(challenge: challenge)
    post passkeys_path, params: { credential: credential.to_json, nickname: nickname }
  end
end
```

- `WebAuthn.configure` の `allowed_origins` に `http://www.example.com` (request spec の既定ホスト) を含める必要があるため、test 環境では `WEBAUTHN_ORIGIN` / `WEBAUTHN_RP_ID` をこの値に合わせる。
- `FakeClient` の API (`create` / `get` の引数、discoverable credential の指定方法) は gem のバージョンで差があるので、Phase 13 で実物に合わせてヘルパーを書く。
- **v1 の担保は request spec で行う。** 実ブラウザの system spec は Chrome DevTools Protocol の Virtual Authenticator が必要でセットアップが重いので後回しにする。system spec はパスワードログインで回す。
