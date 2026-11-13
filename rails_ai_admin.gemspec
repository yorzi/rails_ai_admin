# frozen_string_literal: true

require_relative "lib/rails_ai_admin/version"

Gem::Specification.new do |spec|
  spec.name = "rails_ai_admin"
  spec.version = RailsAiAdmin::VERSION
  spec.authors = [ "Andy Wang" ]
  spec.email = [ "wangyaodi@gmail.com" ]
  spec.summary = "An explicit, authorized Rails admin engine"
  spec.description = "A self-hosted Rails admin with typed resources and a shared, audited operation boundary."
  spec.license = "MIT"
  spec.homepage = "https://github.com/yorzi/rails_ai_admin"
  spec.required_ruby_version = ">= 3.3"
  spec.files = Dir["{app,config,db,lib}/**/*", "README.md", "LICENSE", "SECURITY.md", "CHANGELOG.md", "THIRD_PARTY_NOTICES.md"].select { |path| File.file?(path) }
  spec.require_paths = [ "lib" ]
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["documentation_uri"] = "https://rails-ai-admin.wangyaodi.com/"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"

  spec.add_dependency "base64", "~> 0.3"
  # 8.0.5.2 and 8.1.4.1 are the patched releases of each series; doctor
  # reports an 8.1 below 8.1.4.1, which this requirement cannot exclude.
  spec.add_dependency "rails", ">= 8.0.5.2", "< 8.2"
  spec.add_dependency "json_schemer", "~> 2.5"
  # allow_duplicate_key (template override headers) arrived in json 2.13.
  spec.add_dependency "json", ">= 2.13"
  spec.add_dependency "turbo-rails", "~> 2.0"
  spec.add_dependency "stimulus-rails", "~> 1.3"
end
