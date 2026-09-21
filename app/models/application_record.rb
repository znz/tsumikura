class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  # アプリのテーブルの主キーは UUIDv7 で、URL では Base58 の 22 文字で表す。
  # Solid Queue / Solid Cache のテーブルはこのクラスを継承しないので影響しない
  # (それらは bigint のまま。docs/spec/01-domain-model.md)
  include Base58Param
end
