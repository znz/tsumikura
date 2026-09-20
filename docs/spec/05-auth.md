# 認証とユーザー管理

[概要](00-overview.md) / [データモデル](01-domain-model.md) / [画面](03-screens.md) / [デプロイ](../ops/deployment.md)

## 1. 基本方針

- Rails 8 標準の認証ジェネレータ (`bin/rails generate authentication`) をベースにする。生成物は `User` / `Session` / `Current` / `Authentication` concern / `SessionsController` / `PasswordsController` / `PasswordsMailer`。
- **ログイン ID はメールアドレス** (`users.email_address`) とする。生成物の既定をそのまま使う。メールは**送らない**ので、実在のアドレスである必要はない (家族内で分かる文字列であればよい) が、ID として一意である必要はある。
- **メール送信機能は持たない。** `PasswordsController` と `PasswordsMailer` および関連ビュー・ルートは削除する。パスワードを忘れた場合は**管理者が再設定**する。
- **パスワードは常に必須**。パスキーは追加の認証手段として位置づける。デバイス紛失時に管理者がリセットできる退路を必ず残す。
- 公開サインアップは無い。`/sign_up` に相当する画面を作らない。

### パスワードの要件

- **最小 8 文字** (`User::MINIMUM_PASSWORD_LENGTH`)。最大は `has_secure_password` の 72 バイト。
- 根拠: NIST SP 800-63B の下限が 8 文字であること、ハッシュが bcrypt であること、ログイン試行に `rate_limit` が掛かっていること、家族がスマホで手入力すること、Phase 13 で常用手段をパスキーに移すこと。
- 公開インターネットに置くので、10〜12 文字への引き上げは [未決事項](../plan/open-questions.md) に残す。
- 複雑さの要件 (記号必須など) は課さない。長さだけを見る。

## 2. ユーザーの種類

| 役割 | `role` | できること |
|---|---|---|
| 一般 (member) | 0 | 在庫・記録・買い物リストの全操作、マスタの編集、自分のアカウント設定 |
| 管理者 (admin) | 1 | 上記に加えて、ユーザーの追加・役割変更・無効化・パスワード再設定 |

- 家庭内なので在庫データに対する権限差は設けない。差があるのは**ユーザー管理だけ**。
- ユーザーは**削除しない**。`deactivated_at` を打って無効化する (記録の入力者としての参照が残るため)。無効化されたユーザーはログインできず、既存セッションも失効させる。
- コントローラは `Admin::BaseController` (管理者以外は 403) を親に持つ: `Admin::UsersController` (一覧・追加・編集)、`Admin::DeactivationsController` (無効化 / 再有効化)、`Admin::PasswordResetsController` (パスワード再設定)。
  - 無効化を `UsersController#update` に混ぜないのは、`role` と `deactivated_at` を「編集フォームの permit 対象」にしないため。
  - 管理者が**自分自身**に対してパスワード再設定・無効化を行う導線は一覧に出さない (自分のセッションが消えるだけで得が無い)。自分のパスワードは `/account` から変える。パスワード再設定はコントローラでも自分自身を弾く。

### 最後の管理者の保護

- 有効な管理者が 1 人だけのとき、その管理者の **role 降格**と**無効化**をバリデーションで禁止する (自分自身の操作でも他人の操作でも同じ)。
- 「有効な管理者」の数に**無効化済みの管理者は含めない**。
- 同時実行 (2 人の管理者が同時に降格する) の競合はバリデーションでは防げないが、`tsumikura:create_admin` で必ず復旧できるので対策しない。
- 誰もログインできなくなった場合の復旧手段として、サーバ上で `tsumikura:create_admin` を実行できるようにする ([デプロイ](../ops/deployment.md))。

## 3. 初期セットアップとユーザー追加

```bash
# 最初の管理者 (デプロイ直後に 1 回)
bin/rails tsumikura:create_admin ADMIN_EMAIL=admin@example.com ADMIN_NAME=かんりしゃ
```

| 環境変数 | 既定 | 挙動 |
|---|---|---|
| `ADMIN_EMAIL` | (必須) | 無ければ中断する |
| `ADMIN_NAME` | かんりしゃ | 新規作成時の表示名 |
| `ADMIN_PASSWORD` | (自動生成) | 指定するとそのパスワードにする。**既存ユーザーにも適用される** |
| `ADMIN_RESET_PASSWORD` | — | `1` を渡すと既存ユーザーのパスワードを再生成して 1 度だけ表示する |

- タスクは**冪等**にする。同じメールアドレスで 2 回実行してもユーザーは重複せず、role を admin に揃えるだけにする。
- パスワードは自動生成して標準出力に 1 度だけ表示する。**`ADMIN_PASSWORD` はシェルの履歴や `ps` に平文で残るので、自動生成を使うほうがよい。**
- パスワードを変えたとき (`ADMIN_PASSWORD` / `ADMIN_RESET_PASSWORD`) は、そのユーザーのセッションをすべて失効させる。
- 対象が無効化済みだった場合、**再有効化はしない**。警告を出し、`/admin/users` からの再有効化か別の `ADMIN_EMAIL` での新規作成を促す。
- バリデーションエラー (短すぎる `ADMIN_PASSWORD` など) はスタックトレースではなくメッセージを出して中断する。
- `db/seeds.rb` は ENV なしでも成功する冪等な実装にする (CI の `db:seed:replant` を通すため)。管理者作成は seeds ではなく rake タスクに置く。**固定パスワードの管理者を作るのは development だけ**とし、production / test では何も作らない。

以降の家族アカウントは管理者が `/admin/users` から追加する。

| 操作 | 挙動 |
|---|---|
| 追加 | 名前 + メールアドレスを入力。初期パスワードを自動生成し、**作成直後の画面に 1 度だけ表示**する (再表示はできない) |
| 役割変更 | member <-> admin。最後の管理者は降格できない |
| 無効化 / 再有効化 | `deactivated_at` の設定・解除。最後の管理者は無効化できない。自分自身には出さない |
| パスワード再設定 | 管理者が新しいパスワードを生成し、画面に 1 度だけ表示する (`Admin::PasswordResetsController`)。本人のセッションはすべて失効させる。自分自身には行えない |

### 生成パスワードの形式

- `SecureRandom.alphanumeric(4, chars: ...)` を 4 群、ハイフンで連結する (例: `s4ZC-V5gx-pVLt-C4Eb`)。
- 文字種は 54 種。読み上げ・書き写しで取り違える **`0` `1` `i` `l` `o` `I` `O` `Q` を除外**する。ハイフン区切りも書き写しのため。
- 強度は約 92 bit。管理者が家族に口頭・紙で渡し、受け取った側が `/account` で変える前提の一時パスワードである。

### 「1 度だけ表示」の実装

平文のパスワードを画面に出すのは、追加直後と再設定直後の **POST のレスポンスだけ**とする。

- **リダイレクト + flash 方式は採らない。** flash は Cookie セッション (または `solid_cache` の DB) に平文で載り、リロードや「戻る」で再表示されるため。
- 生成 → `render` で直接描画する。リダイレクトしないので、フォームには `data-turbo="false"` を付ける (Turbo はフォーム POST への 200 非リダイレクト応答を拒否する)。**この属性を外すと「発行されたのに誰も見ていない」状態になる**ので、実ブラウザの system spec (`js: true`) で守る。
- レスポンスに `no_store` を付け、ブラウザ・中間キャッシュに残さない。
- ページに `<meta name="turbo-cache-control" content="no-cache">` を入れ、Turbo のスナップショットキャッシュ (戻る / プレビュー) にも残さない。
- 再設定画面は再読み込みで再 POST になりうるので、「別のパスワードが再発行されます」と注意書きする。
- ログに平文が出ないことは `config/initializers/filter_parameter_logging.rb` の `:passw` (部分一致) で担保する。生成パスワードはそもそもリクエストパラメータに載らない。

## 4. セッション

- Rails 生成のとおり `cookies.signed.permanent` を使う (実質的に長期間ログインしたまま)。家庭用でスマホから頻繁に再ログインさせたくないため。
- 代わりに `/account` に**ログイン中のデバイス一覧**を置き、`sessions` の `ip_address` / `user_agent` / ログイン日時 (`created_at`) を表示して個別に失効できるようにする。「このデバイス以外をログアウト」も置く (`Account::SessionsController`)。
- ログインの試行には `rate_limit to: 10, within: 3.minutes` を掛ける (認証ジェネレータの生成物に含まれる。生成結果を確認してそのまま使う)。パスワード変更 (`Account::PasswordsController#update`) にも同じ制限を掛ける。
- 無効化 (`deactivated_at`) されたユーザーは、パスワードが正しくてもログインできない。エラーメッセージはパスワード誤りと**同じ文言**にして、無効化されていることを伏せる。セッションの復元時 (`resume_session`) にも無効化を確認し、無効化と同時にそのユーザーの `sessions` を全削除する。
- **自分でパスワードを変更するには現在のパスワードが必要**とする (`Account::PasswordsController`)。変更に成功したら、**このデバイス以外のセッションをすべて失効**させる (パスワードが漏れていた場合に備える)。`has_secure_password` は空文字の代入を黙って無視するので、新しいパスワードが空・未送信のときは明示的に弾く。
- **ログイン時とログアウト時に `reset_session`** する (セッション固定攻撃の対策)。ログイン時はログイン前の URL (`return_to_after_authenticating`) を `reset_session` の**前に**読み出す。復帰先を覚えるのは GET / HEAD のときだけにする (POST の URL に GET で戻っても 404 になるだけのため)。
- セッション Cookie (`session_id`) は `httponly` + `SameSite=Lax` (認証ジェネレータの既定)。`secure` は production の `force_ssl` が付ける ([デプロイ](../ops/deployment.md))。
- ログインのパラメータは `params.expect(:email_address, :password)` で受ける。欠けていたり配列で送られたりしたときは 400 にする (`authenticate_by` に渡すと `ArgumentError` で 500 になるため)。

## 5. パスキー (WebAuthn)

### 方針

- `webauthn` gem (3.4.3) を使う。登録は discoverable credential (resident key) にして、**ユーザー名の入力なしでログイン**できるようにする (スマホ中心の UX に効く)。
- パスキーは追加手段であり、パスワードを無効化することはできない。
- パスキーを 1 つも持たないユーザーも普通に使える。全部削除してもパスワードでログインできる。
- **user verification (生体認証・画面ロック・PIN) を必須にする** (`user_verification: "required"` と
  `verify(..., user_verification: true)`)。パスキー 1 つでログインできる = 単独要素なので、
  「持っているだけ」で入れてはいけない。`preferred` だと、PIN を設定していない USB セキュリティキーを
  拾った人が挿してタッチするだけでログインできてしまう (FakeClient で実測して確かめた)。
- 画面は `/account` の「パスキー」セクションに集約する (一覧 / 追加 / 削除)。`/passkeys` の GET は持たない。

### 設定

`config/initializers/webauthn.rb`:

```ruby
webauthn_origin =
  ENV["WEBAUTHN_ORIGIN"].presence ||
  if Rails.env.production?
    "https://#{ENV["APP_HOST"]}" if ENV["APP_HOST"].present?
  elsif Rails.env.test?
    "http://www.example.com"      # request spec の既定ホスト
  else
    "http://localhost:3000"
  end

webauthn_rp_id = ENV["WEBAUTHN_RP_ID"].presence || (URI.parse(webauthn_origin).host if webauthn_origin)

WebAuthn.configure do |config|
  config.allowed_origins = Array(webauthn_origin)
  config.rp_name = "つみくら"
  config.rp_id = webauthn_rp_id
  config.credential_options_timeout = 120_000
end
```

| 環境変数 | 値の例 | 備考 |
|---|---|---|
| `WEBAUTHN_ORIGIN` | `https://tsumikura.example.com` | スキーム + ホスト + (非標準ポート) |
| `WEBAUTHN_RP_ID` | `tsumikura.example.com` | **ホスト名のみ**。スキーム・ポート・パスを含めない |

- **`origin=` (単数) ではなく `allowed_origins` (複数形) を使う** (Phase 13 で gem のソースを読んで確定)。webauthn 3.4.0 で `allowed_origins` が入り、`origin` / `origin=` は非推奨 (呼ぶと警告を出し、将来削除される)。
- **production で `WEBAUTHN_ORIGIN` が未設定なら `APP_HOST` から `https://#{APP_HOST}` を導く。** 設定を 1 つ忘れただけでパスキーが動かないのを避けるため。非標準ポートや別ドメインで公開する場合だけ `WEBAUTHN_ORIGIN` を明示する。
- `APP_HOST` も未設定なら `allowed_origins` が空になり、パスキーは使えないがアプリは起動する (VAPID と同じ方針)。画面は `Passkey.available?` を見て、登録フォームの代わりに案内を出す。
- **origin は `WebauthnOrigin.normalize` (`lib/webauthn_origin.rb`) で正規化してから渡す。** `https://example.com/` の
  ように末尾スラッシュが 1 つ付いているだけで、ceremony は毎回静かに失敗する (画面には「パスキーで
  ログインできませんでした」しか出ない)。空白や壊れた値は `URI.parse` が例外を投げるので、
  **初期化子で投げると起動しなくなる**。正規化できない値は nil に潰し、警告を出してパスキーだけを無効にする。
  このファイルは初期化子から `require_relative` するので、`config.autoload_lib(ignore:)` で Zeitwerk の管理から外してある。
  DB 不要の spec (`spec/lib/webauthn_origin_spec.rb`) で末尾スラッシュ・パス・空白・非標準ポート・不正値を固定している。
- 開発環境は `http://localhost:3000` / `localhost` (localhost は Secure Context 扱いなので HTTPS 不要)。
- **RP ID を変えると、登録済みのパスキーはすべて使えなくなる。** ドメインを移すときは全員が登録し直す ([初回デプロイ手順書](../ops/first-deploy.md#32-webauthn-パスキー))。

### 登録フロー (ログイン済み)

**登録には現在のパスワードの再確認を求める。** セッションを盗んだ者が自分のパスキーを足すと、
パスワードを変えても居座れてしまうため (パスキーはパスワード変更では失効しない)。
challenge を出す前に確かめるので、生体認証のダイアログを出す前に間違いが分かる。

```
1. GET  /account                      パスキーのセクション (一覧 + 「この端末を登録」)
2. POST /passkeys/options             { current_password: "..." }
     user.authenticate(current_password) が false なら 401 (challenge を出さない)
     user.ensure_webauthn_id!         # 初回だけ WebAuthn.generate_user_id
     options = WebAuthn::Credential.options_for_create(
       user: { id: user.webauthn_id, name: user.email_address, display_name: user.name },
       exclude: user.passkeys.pluck(:external_id),
       authenticator_selection: { resident_key: "required", user_verification: "required" }
     )
     session[:passkey_registration_challenge] = { "value" => options.challenge, "issued_at" => ... }
     render json: options
3. JS   navigator.credentials.create({ publicKey: options })
4. POST /passkeys   { credential: "<JSON 文字列>", nickname: "太郎のiPhone" }
     challenge = consume_webauthn_challenge(:passkey_registration_challenge, 5.minutes)  # 期限 + 消費記録
     webauthn_credential = WebAuthn::Credential.from_create(Passkey.parse_credential(params[:credential]))
     webauthn_credential.verify(challenge, user_verification: true)
     Current.user.passkeys.create!(external_id:, public_key:, sign_count:, nickname:)
5. JS   成功したときだけ Turbo.visit で /account を描き直す (一覧に新しい行が出る)
```

- **challenge のセッションキーは登録用と認証用で必ず分ける** (`:passkey_registration_challenge` /
  `:passkey_authentication_challenge`)。同じキーにすると、未ログインで叩ける
  `/sessions/passkey/options` で発行した challenge を、パスワードの再確認なしの登録に使い回せてしまう。
- `nickname` が空なら User-Agent から既定値を付ける (`iPhone / Safari` など。`push_device_label` を共用)。50 文字で切り詰める。
- `user_id` / `external_id` / `public_key` / `sign_count` はフォームから設定できない (`Current.user.passkeys.create!` に明示した値だけを渡す)。
- 削除は `Current.user.passkeys.find_by(id:)` なので**他人のパスキーは消せない**。すでに消えている行への削除も 404 にせず `/account` に戻す (古い画面からの操作)。

### 認証フロー (usernameless)

```
1. POST /sessions/passkey/options     (allow_unauthenticated_access)
     options = WebAuthn::Credential.options_for_get(user_verification: "required")
     # allow_credentials を渡さない = discoverable credential を使う
     session[:passkey_authentication_challenge] = { "value" => options.challenge, "issued_at" => ... }
2. JS   navigator.credentials.get({ publicKey: options, mediation: "conditional" })
        # conditional UI でメール欄にパスキー候補を出すと 1 タップになる
        # 「パスキーでログイン」ボタンからは mediation: "optional"
3. POST /sessions/passkey  { credential: "<JSON 文字列>" }
     challenge = consume_webauthn_challenge(:passkey_authentication_challenge, 15.minutes)  # 期限 + 消費記録
     webauthn_credential = WebAuthn::Credential.from_get(Passkey.parse_credential(params[:credential]))
     passkey = Passkey.find_by(external_id: webauthn_credential.id)   # 見つからなければ拒否
     webauthn_credential.verify(challenge, public_key: passkey.public_key, sign_count: passkey.sign_count,
                                user_verification: true)
     拒否: webauthn_credential.user_handle が登録時の user.webauthn_id と違う
     passkey.update!(sign_count: webauthn_credential.sign_count, last_used_at: Time.current)
     拒否: passkey.user.deactivated?
     start_authenticated_session_for(passkey.user)   # Authentication concern
     render json: { redirect_url: ... }
4. JS   Turbo.visit(redirect_url)
```

- **challenge の「1 回限り」は `session.delete` だけでは成り立たない** (`WebauthnChallenge` concern)。
  セッションは CookieStore なので、`delete` は「次に返す Cookie から消す」だけで、challenge を含む
  **古い Cookie はサーバから見ると永久に有効**なまま。次の 2 つで担保する。
  1. **有効期限**: challenge と一緒に発行時刻 (`issued_at`) を入れ、期限を過ぎたものは使わない。
     登録は 5 分 (生体認証をキャンセルしたまま残る時間を切り詰める)、認証は 15 分
     (conditional UI はログイン画面を開いたまま待つ)。
  2. **サーバ側の消費記録**: 使おうとした時点で SHA256 のダイジェストを `Rails.cache` に
     `unless_exist: true` で書き、2 回目は断る (成功・失敗にかかわらず消費する)。production は solid_cache。
  - これが無いと、ログイン前の Cookie と assertion の組を入手されたときに、**`sign_count` を常に 0 で返す
    同期型のパスキー (iCloud / Google) ではカウンタ検証にも引っかからず何度でもログインできる**。
  - 登録側では、生体認証をキャンセルしたあとにセッションに残った challenge を盗まれると、
    パスワードの再確認なしで攻撃者の認証器を登録できてしまう (期限がこれを切る)。
  - test の `cache_store` は `:null_store` なので、消費記録を試す spec だけ `:memory_cache` の
    メタデータで `MemoryStore` に差し替える (`spec/support/cache_helper.rb`)。
- 認証器が `userHandle` を返したときは、登録時の `user.webauthn_id` と一致することを確かめる
  (別のユーザーの credential ID を混ぜられないように)。返さない認証器もあるので、あるときだけ見る。
- `credential` の `id` が String であることを `Passkey.parse_credential` で確かめる。gem は Hash や配列の
  `id` をそのまま通すので、検証より前に走る `Passkey.find_by(external_id:)` に配列が渡って IN 検索になる。
- **広い rescue は gem を呼ぶ数行だけ**に閉じ込める (`parsed_assertion` / `assertion_valid?`)。
  DB 操作やログインの手順まで巻き込むと、本物の不具合を静かな 401 に変えてしまう。
- ログインの手順 (`after_authentication_url` を読む → `reset_session` → `start_new_session_for`) は
  `Authentication#start_authenticated_session_for` に出して、**パスワードログインと同じ経路を通す**。
  ログイン前に開こうとした URL に戻るのも、セッション固定攻撃の対策も同じになる。
- **失敗はすべて同じ文言・同じステータス (401)** にする。credential が存在しない / 検証に失敗した /
  ユーザーが無効化されている、を区別しない (登録の有無やアカウントの存在を漏らさないため)。
- `sign_count` は**断る場合でも先に更新する** (クローン検知のカウンタを進めておく)。
- `rate_limit` は options と create の**両方**に掛ける。1 つのコントローラに複数置くので `name:` で分ける
  (付けないと同じキーを取り合う)。
  - `/sessions/passkey/options`: **30 回 / 3 分**。conditional UI のためにログイン画面を開くたびに 1 回呼ばれ、家族全員が同じ回線 (= 同じ IP) から来るため多めに取る。challenge を配るだけで、当てるにはパスキーの秘密鍵が要る。
  - `/sessions/passkey`: **10 回 / 3 分** (パスワードログインと同じ)。
  - `/passkeys/options` と `/passkeys`: それぞれ 10 回 / 3 分 (パスワード変更と同じ)。
- 壊れた入力で 500 にしない。webauthn gem は検証の失敗を `WebAuthn::Error` で投げるが、**形が壊れた
  入力ではそれ以外の例外になる**ことを `mise x -- ruby -e` + FakeClient で実測した (`Passkey::VERIFICATION_ERRORS` にまとめてある):

  | 入力 | 例外 |
  |---|---|
  | base64url として壊れている | `ArgumentError` |
  | `response` やキーが欠けている | `ArgumentError` / `NoMethodError` / `TypeError` |
  | `type` / `id` が食い違う | `RuntimeError` (gem の `raise("invalid type")`) |
  | 公開鍵・attestation のデコード失敗 | `COSE::Error` / `CBOR::UnpackError` |
  | challenge が String でない (未発行・期限切れ・使用済みで nil) | `WebAuthn::PublicKeyCredential::InvalidChallengeError` |
  | 生体認証 / PIN を通していない | `WebAuthn::UserVerifiedVerificationError` |

- `credential` は **JSON 文字列**で受ける。文字列でない / Hash にならない入力は `Passkey.parse_credential` が
  gem に渡す前に弾く。
- ログに残さないよう `config/initializers/filter_parameter_logging.rb` に `:credential` / `:public_key` を足す
  (challenge は Rails セッションの中なのでパラメータには出ない)。

> 同期型のパスキー (iCloud キーチェーン、Google パスワードマネージャー) は `sign_count` を常に 0 で返すことが多い。WebAuthn の仕様上、保存値も受信値も 0 の場合はカウンタ検証の対象外なので、そのまま動く。巻き戻った場合は gem が `WebAuthn::SignCountVerificationError` を投げるので、こちらは拒否になる。

### 無効化・パスワード再設定との関係

| 操作 | パスキー |
|---|---|
| ユーザーの無効化 (`deactivated_at`) | **消さない** (無効化は取り消せるため)。ログイン側が無効化を見て断るので、無効化中はパスキーでも入れない |
| 自分でのパスワード変更 (`/account`) | 消さない (本人の操作なので) |
| 管理者によるパスワード再設定 | **すべて消す**。再設定は「乗っ取られたかもしれない」ときの操作でもあり、攻撃者が登録したパスキーを残すと入り続けられる。確認画面に件数を出し、完了画面で「n 件も削除しました」と伝える |

- `passkeys.user_id` の外部キーは `on_delete: :restrict` (ユーザーは物理削除しない)。`User` 側は `dependent: :destroy`。

### JavaScript

- **webauthn-json のようなライブラリは足さない。** `PublicKeyCredential.parseCreationOptionsFromJSON` /
  `parseRequestOptionsFromJSON` と `credential.toJSON()` が使えるブラウザではそれを使い、無いブラウザ向けに
  base64url <-> ArrayBuffer の変換を `app/javascript/passkey_codec.js` に持つ (gem が返す JSON では
  `challenge` / `user.id` / `excludeCredentials[].id` / `allowCredentials[].id` が base64url)。
- Stimulus の controller は 2 つ。Phase 12 の `push_subscription_controller.js` と同じ型
  ((1) 機能検出 → (2) 表示の切り替え → (3) エラー処理) にそろえる。
  - `passkey_controller.js` (登録。`/account`)
  - `passkey_login_controller.js` (認証。ログイン画面。conditional UI を含む)
- **未対応のブラウザではボタン・フォームを出さない** (サーバ側で `hidden` にしておき、controller が外す)。
- `fetch` は**セッション切れのリダイレクト追従**を必ず見る (`response.redirected` と `content-type`)。
  302 に追従したログイン画面の 200 を成功と誤認しない。
- ユーザーのキャンセル (`NotAllowedError`) と中断 (`AbortError`) は**静かに戻す**。
  `InvalidStateError` は「この端末のパスキーはすでに登録されています。」と出す。
- **ceremony は同時に 1 つしか始められない。** conditional とボタンが競合するので、controller は
  通し番号 (`this.run`) を持ち、**後から始まったものだけが画面と遷移を触る**。これが無いと、
  中断された側の `catch` が後発の「確認しています…」を消してしまう。`get` の直前でも前の ceremony を畳む。
  ボタンをキャンセルしたあとは conditional UI を再開する (再開しないとメール欄の候補が二度と出ない)。
  Turbo のプレビュー描画 (`data-turbo-preview`) では何もしない (すぐ本物の描画で `connect` し直される)。
- challenge には期限があるので、conditional UI は 401 で戻ってきたら **1 度だけ** options を取り直してやり直す。
- conditional UI は `PublicKeyCredential.isConditionalMediationAvailable()` が true のときだけ始め、
  `AbortController` を持って `disconnect()` で畳む (Turbo で画面を離れたまま ceremony が残ると、
  次の `navigator.credentials.get` が失敗する)。ボタンを押したときも先に畳む
  (同時に 2 つの ceremony は始められない)。
- ログイン画面のメール欄に `autocomplete="username webauthn"` を付ける (conditional UI の候補がここに出る)。

### テスト方法

```ruby
# spec/support/webauthn_helper.rb
require "webauthn/fake_client"

module WebauthnHelper
  DEFAULT_ORIGIN = "http://www.example.com".freeze

  def fake_client(origin = DEFAULT_ORIGIN)
    @fake_client ||= WebAuthn::FakeClient.new(origin, authenticator: fake_authenticator)
  end

  def fake_authenticator
    @fake_authenticator ||= WebAuthn::FakeAuthenticator.new
  end
end
```

Phase 13 で実物に当てて確かめた `WebAuthn::FakeClient` (3.4.3) の API:

- `create(challenge:, rp_id: nil, user_present: true, user_verified: false, ...)` と
  `get(challenge:, rp_id: nil, sign_count: nil, ...)` は **`Hash` を返す** (JSON 文字列ではない)。
  コントローラには `credential.to_json` を送る。
- `challenge:` には `options.challenge` (base64url の**文字列**) をそのまま渡す。
- `create` は**呼ぶたびに新しい credential を作る**。同じ credential を 2 回登録させる spec は書けない。
- `get` は認証器が `rp_id` ごとに覚えている credential から返す。`rp_id` は既定で origin のホスト。
- **`authenticator:` を共有した別 origin のクライアント**を作り、`get(rp_id: <本物の RP ID>)` を呼ぶと、
  「本物の credential を別 origin のページから使った」状況 (フィッシング) を再現できる。
  `origin` だけが違うので `WebAuthn::OriginVerificationError` になる。
- 登録直後の `credential.sign_count` は 0。以降の `get` は 1, 2, ... と増える
  (`sign_count:` を渡すとその値になる。巻き戻しの spec に使う)。
- `WebAuthn.configure` の `allowed_origins` に `http://www.example.com` (request spec の既定ホスト) を
  含める必要があるため、test 環境の既定 origin をこの値にしてある。

- **v1 の担保は request spec で行う。** 実ブラウザの system spec は Chrome DevTools Protocol の
  Virtual Authenticator が必要でセットアップが重いので後回しにする ([未決事項](../plan/open-questions.md))。
  system spec はパスワードログインで回す。ビューに Stimulus の `data-*` 属性とボタンが出ていることは
  request spec で固定してある。

### 実機での確認手順 (HTTPS の本番環境で)

パスキーは `localhost` 以外では HTTPS が要り、認証器はブラウザとハードウェアに依存するので、
以下は**実機でしか確認できない**。初回デプロイ後に上から順に試す。

1. **iPhone (Face ID / Touch ID)**
   - Safari で `https://<APP_HOST>` を開き、パスワードでログイン → メニュー → アカウント設定。
   - 「パスキー」セクションに「この端末にパスキーを登録」が**出ている**こと (出ないなら `WEBAUTHN_ORIGIN` か HTTPS を疑う)。
   - 名前を空のまま現在のパスワードを入れて登録 → Face ID → 一覧に「iPhone / Safari」の行が増える。
   - ログアウト → ログイン画面で**メール欄をタップ**し、候補にパスキーが出る (conditional UI) → 選んで Face ID → ログインできる。
   - 候補が出ないときは「パスキーでログイン」ボタンから。
   - 「ホーム画面に追加」した PWA からも同じように動くこと。
2. **Android (Google パスワードマネージャー)**
   - Chrome で同様に登録 → 画面ロックで確認 → ログアウトして usernameless ログイン。
   - 同期されたパスキーは `sign_count` が 0 のままでもログインできること (一覧の「最終利用」が更新される)。
3. **PC (セキュリティキー / Windows Hello / Touch ID)**
   - USB のセキュリティキーでも登録・ログインできること。**PIN を設定していないキーでは、
     登録のときにブラウザが PIN の設定を求めてくる** (user verification を必須にしているため)。
     PIN を設定せずに進めると登録できないのが正しい。
   - 登録済みの端末でもう一度「登録」を押すと「この端末のパスキーはすでに登録されています。」と出ること (`excludeCredentials` が効いている)。
4. **まわりの確認**
   - パスキーを削除すると、その端末ではパスキーでログインできなくなる (パスワードでは入れる)。
   - 管理者がパスワードを再設定すると、そのユーザーのパスキーが消える。
   - 管理者がユーザーを無効化すると、パスキーでもログインできない。
   - 未対応のブラウザ (古い Firefox など) では「パスキーでログイン」ボタンが**出ない**。
