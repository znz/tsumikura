# spec/tasks/*_spec.rb を Rails の example group として扱う。
# rspec-rails が知らない type (:task) には RailsExampleGroup が入らないため、
# トランザクションでのロールバックが効かず spec 間でデータが残ってしまう。
module RakeTaskHelper
  # タスクの出力 (標準出力 + 標準エラー) と終了コード
  Result = Struct.new(:output, :status) do
    def ok?
      status.zero?
    end
  end

  # rake タスクを実行し、出力と終了コードを返す。
  # exit / abort は SystemExit を上げるので、raise_error で捕まえると出力が取れない。
  # ここで rescue して終了コードとして返す (再実行できるよう reenable する)。
  # abort のメッセージは標準エラーに出るので、両方を同じ StringIO に集める
  def run_rake_task(name)
    io = StringIO.new
    original_stdout = $stdout
    original_stderr = $stderr
    $stdout = io
    $stderr = io
    status = 0

    begin
      Rake::Task[name].reenable
      Rake::Task[name].invoke
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = original_stdout
      $stderr = original_stderr
    end

    Result.new(io.string, status)
  end
end

RSpec.configure do |config|
  config.define_derived_metadata(file_path: %r{/spec/tasks/}) do |metadata|
    metadata[:type] ||= :task
  end

  config.include RSpec::Rails::RailsExampleGroup, type: :task
  config.include RakeTaskHelper, type: :task
end
