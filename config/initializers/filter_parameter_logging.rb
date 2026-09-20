# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  # Web Push の購読 (docs/spec/04-notifications.md 3 節)。endpoint は端末を特定できる URL で、
  # p256dh / auth は通知を復号するための鍵なので、ログに残さない
  # (:_key が p256dh_key / auth_key を、:auth が JS から来る keys.auth を拾う)
  :endpoint, :p256dh, :auth,
  # パスキー (docs/spec/05-auth.md 5 節)。credential は認証器の応答 (署名を含む)、
  # public_key は COSE の公開鍵。どちらも端末を特定できるのでログに残さない
  # (:_key が public_key を拾うが、明示しておく)
  :credential, :public_key
]
