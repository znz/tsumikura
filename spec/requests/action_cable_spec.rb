require "rails_helper"

RSpec.describe "Action Cable", type: :request do
  # app/channels を消しても ActionCable::Engine は /cable をマウントし、
  # 素の Connection::Base が未認証の WebSocket を受け付けてしまう。
  # リアルタイム配信は行わない方針なので、マウント自体を外す (docs/ops/deployment.md 1.1 節)
  it "/cable はマウントされていない" do
    get "/cable"

    expect(response).to have_http_status(:not_found)
  end

  it "ログイン済みでも /cable はマウントされていない" do
    sign_in create(:user)

    get "/cable"

    expect(response).to have_http_status(:not_found)
  end
end
