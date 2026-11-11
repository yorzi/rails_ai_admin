# frozen_string_literal: true

require_relative "lib/rails_ai_admin/version"

Gem::Specification.new do |spec|
  spec.name = "rails_ai_admin"
  spec.version = RailsAiAdmin::VERSION
  spec.authors = [ "Andy Wang" ]
  spec.email = [ "wangyaodi@gmail.com" ]
  spec.summary = "An explicit, authorized Rails admin engine"
  spec.description = "A self-hosted Rails admin with typed resources and a shared, audited operation boundary. Unreleased development."
  spec.license = "MIT"
  spec.homepage = "https://github.com/yorzi/rails_ai_admin"
  spec.required_ruby_version = ">= 4.0.9"
  spec.files = Dir["{app,config,db,lib}/**/*", "README.md", "LICENSE", "SECURITY.md", "CHANGELOG.md", "THIRD_PARTY_NOTICES.md"].select { |path| File.file?(path) }
  spec.require_paths = [ "lib" ]
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  # Prevent an accidental release before the explicit owner approval gate.
  spec.metadata["allowed_push_host"] = "https://unreleased.invalid"

  spec.add_dependency "base64", "~> 0.3"
  spec.add_dependency "rails", ">= 8.1.4.1", "< 8.2"
  spec.add_dependency "json_schemer", "~> 2.5"
  spec.add_dependency "turbo-rails", "~> 2.0"
  spec.add_dependency "stimulus-rails", "~> 1.3"
end
