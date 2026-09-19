# spec/tasks/*_spec.rb を Rails の example group として扱う。
# rspec-rails が知らない type (:task) には RailsExampleGroup が入らないため、
# トランザクションでのロールバックが効かず spec 間でデータが残ってしまう。
RSpec.configure do |config|
  config.define_derived_metadata(file_path: %r{/spec/tasks/}) do |metadata|
    metadata[:type] ||= :task
  end

  config.include RSpec::Rails::RailsExampleGroup, type: :task
end
