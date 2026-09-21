require "rails_helper"
require "rake"

RSpec.describe "tsumikura:create_admin", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  def admin_env_keys
    %w[ ADMIN_EMAIL ADMIN_NAME ADMIN_PASSWORD ADMIN_RESET_PASSWORD ]
  end

  around do |example|
    saved = ENV.to_h.slice(*admin_env_keys)
    begin
      example.run
    ensure
      admin_env_keys.each { |key| ENV.delete(key) }
      saved.each { |key, value| ENV[key] = value }
    end
  end

  # 標準出力を捕まえつつタスクを実行する (再実行できるよう reenable する)
  def run_task
    io = StringIO.new
    original = $stdout
    $stdout = io
    begin
      Rake::Task["tsumikura:create_admin"].reenable
      Rake::Task["tsumikura:create_admin"].invoke
    ensure
      $stdout = original
    end
    io.string
  end

  it "ADMIN_EMAIL が無ければ中断する" do
    ENV["ADMIN_NAME"] = "かんりしゃ"

    expect { run_task }.to raise_error(SystemExit)
    expect(User.count).to eq 0
  end

  describe "新規作成" do
    before do
      ENV["ADMIN_EMAIL"] = "admin@example.com"
      ENV["ADMIN_NAME"] = "かんりしゃ"
    end

    it "管理者が作られる" do
      expect { run_task }.to change { User.count }.by(1)

      user = User.find_by(email_address: "admin@example.com")
      expect(user).to be_admin
      expect(user.name).to eq "かんりしゃ"
      expect(user).not_to be_deactivated
    end

    it "自動生成したパスワードを標準出力に表示する" do
      output = run_task
      password = output[/パスワード: (\S+)/, 1]

      expect(password).to be_present
      expect(User.find_by(email_address: "admin@example.com").authenticate(password)).to be_truthy
    end

    it "ADMIN_NAME が無くても作れる" do
      ENV.delete("ADMIN_NAME")

      expect { run_task }.to change { User.count }.by(1)
      expect(User.last.name).to be_present
    end

    it "ADMIN_PASSWORD を指定するとそのパスワードになり、標準出力には出さない" do
      ENV["ADMIN_PASSWORD"] = "chosen-password"

      output = run_task

      expect(User.last.authenticate("chosen-password")).to be_truthy
      expect(output).not_to include "chosen-password"
    end

    it "メールアドレスは小文字に正規化される" do
      ENV["ADMIN_EMAIL"] = "Admin@Example.com"

      run_task

      expect(User.last.email_address).to eq "admin@example.com"
    end
  end

  describe "冪等性" do
    before do
      ENV["ADMIN_EMAIL"] = "admin@example.com"
      ENV["ADMIN_NAME"] = "かんりしゃ"
    end

    it "2 回実行してもユーザーが重複しない" do
      run_task

      expect { run_task }.not_to change { User.count }
    end

    it "2 回目は既に存在する旨を表示する" do
      run_task

      expect(run_task).to include "既に"
    end

    it "2 回目はパスワードを変更しない" do
      password = run_task[/パスワード: (\S+)/, 1]

      run_task

      expect(User.last.authenticate(password)).to be_truthy
    end

    it "既存の一般ユーザーは管理者に昇格する" do
      member = create(:user, email_address: "admin@example.com")

      run_task

      expect(member.reload).to be_admin
    end

    it "ADMIN_PASSWORD を指定すれば既存ユーザーのパスワードを再設定できる" do
      create(:user, email_address: "admin@example.com")
      ENV["ADMIN_PASSWORD"] = "recovery-password"

      run_task

      expect(User.last.authenticate("recovery-password")).to be_truthy
    end

    it "パスワードを変えないときはセッションを失効させない" do
      user = create(:user, email_address: "admin@example.com")
      user.sessions.create!(ip_address: "127.0.0.1", user_agent: "rspec")

      expect { run_task }.not_to change { user.sessions.count }
    end
  end

  describe "パスワードの再設定 (ロックアウトからの復旧)" do
    before do
      ENV["ADMIN_EMAIL"] = "admin@example.com"
      ENV["ADMIN_NAME"] = "かんりしゃ"
    end

    it "ADMIN_RESET_PASSWORD=1 でパスワードを再生成し、標準出力に 1 度だけ表示する" do
      create(:user, :admin, email_address: "admin@example.com")
      ENV["ADMIN_RESET_PASSWORD"] = "1"

      password = run_task[/パスワード: (\S+)/, 1]

      expect(password).to be_present
      expect(User.last.authenticate(password)).to be_truthy
      expect(User.last.authenticate("family-password")).to be false
    end

    it "ADMIN_RESET_PASSWORD=1 で対象ユーザーのセッションが失効する" do
      user = create(:user, :admin, email_address: "admin@example.com")
      user.sessions.create!(ip_address: "127.0.0.1", user_agent: "rspec")
      ENV["ADMIN_RESET_PASSWORD"] = "1"

      expect { run_task }.to change { user.sessions.count }.to(0)
    end

    it "ADMIN_PASSWORD で再設定したときもセッションが失効する" do
      user = create(:user, :admin, email_address: "admin@example.com")
      user.sessions.create!(ip_address: "127.0.0.1", user_agent: "rspec")
      ENV["ADMIN_PASSWORD"] = "recovery-password"

      expect { run_task }.to change { user.sessions.count }.to(0)
    end
  end

  describe "無効化済みユーザー" do
    before do
      ENV["ADMIN_EMAIL"] = "admin@example.com"
      ENV["ADMIN_NAME"] = "かんりしゃ"
    end

    it "再有効化はせず、警告と代替手段を表示する" do
      create(:user, :admin)
      user = create(:user, :deactivated, email_address: "admin@example.com")

      output = run_task

      expect(user.reload).to be_deactivated
      expect(output).to include "無効化されています"
      expect(output).to include "別の ADMIN_EMAIL"
    end
  end

  describe "バリデーションエラー" do
    before { ENV["ADMIN_EMAIL"] = "admin@example.com" }

    it "短すぎる ADMIN_PASSWORD ではスタックトレースではなく中断する" do
      ENV["ADMIN_PASSWORD"] = "a" * (User::MINIMUM_PASSWORD_LENGTH - 1)

      expect { run_task }.to raise_error(SystemExit)
      expect(User.count).to eq 0
    end

    it "不正な ADMIN_EMAIL では中断する" do
      ENV["ADMIN_EMAIL"] = "かんりしゃ"

      expect { run_task }.to raise_error(SystemExit)
      expect(User.count).to eq 0
    end
  end
end
