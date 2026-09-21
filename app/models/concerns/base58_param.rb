# URL に出る id を Base58 の 22 文字にする (docs/spec/03-screens.md)。
#
# アプリの主キーは UUIDv7 (docs/spec/01-domain-model.md)。連番と違って件数や前後のレコードを
# 推測できないが、36 文字のままだと URL が読みにくいので Base58 で 22 文字に縮める。
#
# **生の UUID は URL では受け付けない** (find_by_param! は 22 文字の Base58 以外を
# そのまま RecordNotFound にする)。URL の表現を 1 つに保ち、
# 「UUID なら通る / Base58 なら通る」の二重の入口を作らないため。
#
# 変換そのものは lib/base58_uuid.rb (Rails にも DB にも依存しない純粋な関数)。
module Base58Param
  extend ActiveSupport::Concern

  # 主キーが UUID でない DB (UUIDv7 化より前の bigint) にこのコードを当てると、
  # ここが Base58Uuid::NotUuidPrimaryKey になる。migration のバージョン番号は変えていないので
  # db:migrate / db:prepare は「未適用なし」で黙って成功してしまうため、
  # 原因が分かるメッセージで落とす (docs/ops/deployment.md 10 節)
  def to_param
    id && Base58Uuid.encode_primary_key(id)
  end

  class_methods do
    # コントローラの find(params[:id]) の置き換え。
    # 不正な Base58 は 500 ではなく 404 にする (ActiveRecord::RecordNotFound)。
    # relation / 関連からも呼べる (Current.user.passkeys.find_by_param!(...) など)
    def find_by_param!(param)
      find(uuid_from_param!(param))
    end

    # 「無ければ nil」。消えている行への操作を 404 ではなく案内に倒す画面で使う
    def find_by_param(param)
      uuid = Base58Uuid.decode_or_nil(param)

      uuid && find_by(id: uuid)
    end

    def uuid_from_param!(param)
      Base58Uuid.decode(param)
    rescue ArgumentError
      raise ActiveRecord::RecordNotFound, "Couldn't find #{name} with param=#{param.inspect}"
    end
  end
end
