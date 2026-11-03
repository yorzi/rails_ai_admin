# frozen_string_literal: true

require "digest"
require "open3"
require "rubygems"
require "yaml"

# Mechanical release-readiness checks. It never builds, tags or publishes, and a
# clean report is not a release decision: product gates and owner approval stay
# in RELEASING.md.
class ReleaseCheck
  Check = Struct.new(:name, :status, :message)
  BLOCKED_PUSH_HOST = "https://unreleased.invalid"
  SHIPPED_ROOTS = %w[app/ config/ db/ lib/].freeze
  HOST_GEMFILES = %w[spec_hosts/session_sqlite/Gemfile spec_hosts/devise_postgres/Gemfile].freeze

  def initialize(root)
    @root = File.expand_path(root)
  end

  def version
    @version ||= begin
      source = File.read(File.join(@root, "lib/rails_ai_admin/version.rb"))
      source[/VERSION = "([^"]+)"/, 1] or raise "VERSION constant not found"
    end
  end

  def checks
    first = version_check
    # Every later check compares against the version, so stop at a bad one.
    return [ first ] if first.status == :error
    [ first, host_pins_check, docs_config_check, changelog_check, package_files_check,
      metadata_check, publish_gate_check, worktree_check, package_digest_check ]
  end

  def errors = checks.select { |check| check.status == :error }

  private

  def prerelease? = Gem::Version.new(version).prerelease?

  def version_check
    raise ArgumentError unless Gem::Version.correct?(version)
    Check.new("version", :ok, "#{version} (#{prerelease? ? 'prerelease' : 'release'})")
  rescue ArgumentError
    Check.new("version", :error, "#{version.inspect} is not a valid gem version")
  end

  def host_pins_check
    stale = HOST_GEMFILES.reject { |path| File.read(File.join(@root, path)).include?(%(gem "rails_ai_admin", "#{version}")) }
    return Check.new("host_pins", :ok, "Packaged hosts pin #{version}") if stale.empty?
    Check.new("host_pins", :error, "Update the exact rails_ai_admin pin in #{stale.join(', ')}")
  end

  def docs_config_check
    config = YAML.safe_load_file(File.join(@root, "docs/site/_config.yml"))
    problems = []
    problems << "version is #{config['version'].inspect}" unless config["version"] == version
    problems << "released must be #{!prerelease?}" unless config["released"] == !prerelease?
    return Check.new("docs_config", :ok, "docs/site/_config.yml matches #{version}") if problems.empty?
    Check.new("docs_config", :error, "docs/site/_config.yml: #{problems.join('; ')}")
  end

  def changelog_check
    headings = File.read(File.join(@root, "CHANGELOG.md")).scan(/^## (.+)$/).flatten.map(&:strip)
    if prerelease?
      return Check.new("changelog", :ok, "Unreleased section present") if headings.first == "Unreleased"
      return Check.new("changelog", :error, "Start CHANGELOG.md with an Unreleased section")
    end
    return Check.new("changelog", :ok, "#{version} section present") if headings.include?(version) || headings.any? { |heading| heading.start_with?("#{version} ") }
    Check.new("changelog", :error, "Add a `## #{version}` section to CHANGELOG.md")
  end

  # The gemspec globs the tree, so an untracked local file would ship silently.
  def package_files_check
    spec = Dir.chdir(@root) { Gem::Specification.load("rails_ai_admin.gemspec") }
    return Check.new("package_files", :error, "rails_ai_admin.gemspec did not load") unless spec
    tracked, status = Open3.capture2("git", "-C", @root, "ls-files", "-z")
    return Check.new("package_files", :review, "git ls-files failed; package contents unverified") unless status.success?
    tracked = tracked.split("\0")
    untracked = spec.files - tracked
    outside = spec.files.reject { |path| SHIPPED_ROOTS.any? { |root| path.start_with?(root) } || File.dirname(path) == "." }
    missing = tracked.select { |path| SHIPPED_ROOTS.any? { |root| path.start_with?(root) } } - spec.files
    problems = []
    problems << "untracked files would ship: #{untracked.first(5).join(', ')}" if untracked.any?
    problems << "files outside app/config/db/lib would ship: #{outside.first(5).join(', ')}" if outside.any?
    problems << "tracked runtime files are not packaged: #{missing.first(5).join(', ')}" if missing.any?
    return Check.new("package_files", :ok, "#{spec.files.size} packaged files, all tracked") if problems.empty?
    Check.new("package_files", :error, problems.join("; "))
  end

  def metadata_check
    spec = Dir.chdir(@root) { Gem::Specification.load("rails_ai_admin.gemspec") }
    required = %w[source_code_uri changelog_uri bug_tracker_uri]
    missing = required.reject { |key| spec.metadata[key].to_s.start_with?("https://") }
    missing << "rubygems_mfa_required" unless spec.metadata["rubygems_mfa_required"] == "true"
    missing << "license" unless spec.license == "MIT"
    return Check.new("metadata", :ok, "MIT, MFA required, source/changelog/bug tracker URIs") if missing.empty?
    Check.new("metadata", :error, "Missing gemspec metadata: #{missing.join(', ')}")
  end

  # Publishing stays blocked in the gemspec until the owner approves a release.
  def publish_gate_check
    spec = Dir.chdir(@root) { Gem::Specification.load("rails_ai_admin.gemspec") }
    host = spec.metadata["allowed_push_host"]
    if host == BLOCKED_PUSH_HOST
      return Check.new("publish_gate", prerelease? ? :closed : :error,
        "allowed_push_host blocks `gem push`. Only the owner changes it, in the release commit, after approval.")
    end
    return Check.new("publish_gate", :error, "allowed_push_host is open in a prerelease build") if prerelease?
    Check.new("publish_gate", :review, "allowed_push_host is #{host}; confirm the owner's recorded approval")
  end

  def worktree_check
    output, status = Open3.capture2("git", "-C", @root, "status", "--porcelain")
    return Check.new("worktree", :review, "git status failed") unless status.success?
    return Check.new("worktree", :ok, "Clean working tree") if output.empty?
    Check.new("worktree", :review, "#{output.lines.size} uncommitted paths; release from a clean tagged commit")
  end

  def package_digest_check
    path = File.join(@root, "pkg/rails_ai_admin-#{version}.gem")
    return Check.new("package", :review, "No pkg/rails_ai_admin-#{version}.gem; run `rake build`") unless File.file?(path)
    Check.new("package", :ok, "pkg/rails_ai_admin-#{version}.gem sha256=#{Digest::SHA256.file(path).hexdigest}")
  end
end
