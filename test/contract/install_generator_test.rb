# frozen_string_literal: true

require "test_helper"
require "support/application"
require "generators/rails_ai_admin/install/install_generator"
require "minitest/mock"
require "tmpdir"

class InstallUser < ActiveRecord::Base; end
class InstallSession < ActiveRecord::Base
  belongs_to :user, class_name: "InstallUser"
end

# The installer writes a working context for the sign-in system it finds and
# a policy that is closed unless --full-access asks for the preset.
class InstallGeneratorTest < Minitest::Test
  Request = Struct.new(:cookie_jar, :env)
  Controller = Struct.new(:request)
  Jar = Struct.new(:signed)
  Warden = Struct.new(:user) do
    def authenticate(scope:) = scope == :user || scope == :admin_user ? user : nil
  end
  Mapping = Struct.new(:name, :class_name)

  def setup
    ActiveRecord::Schema.define do
      create_table :install_users, force: true do |t|
        t.string :email_address, null: false
        t.boolean :admin, null: false, default: false
        t.timestamps
      end
      create_table :install_sessions, force: true do |t|
        t.references :user
        t.timestamps
      end
    end
    InstallUser.reset_column_information
    @user = InstallUser.create!(email_address: "staff@example.test")
  end

  def teardown
    %i[AdminContext AdminPolicyAdapter Session].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name, false) }
  end

  def install(flags = {}, concern: false, routes: nil)
    Rails.application.routes.url_helpers.rails_ai_admin_path
    isolated = ActionDispatch::Routing::RouteSet.new
    RailsAiAdmin::Engine.instance.stub(:routes, ->(*) { isolated }) do
      Dir.mktmpdir("raa-install-", File.expand_path("../../tmp", __dir__)) do |directory|
        FileUtils.mkdir_p(File.join(directory, "config"))
        File.write(File.join(directory, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")
        if concern
          FileUtils.mkdir_p(File.join(directory, "app/controllers/concerns"))
          File.write(File.join(directory, "app/controllers/concerns/authentication.rb"), "module Authentication\nend\n")
        end
        application = Struct.new(:root, :routes).new(Pathname.new(directory), ActionDispatch::Routing::RouteSet.new)
        application.routes.draw(&routes) if routes
        generator = RailsAiAdmin::Generators::InstallGenerator.new([], { force: true, **flags }, destination_root: directory, application: application)
        yield generator if block_given?
        output, = capture_io { generator.invoke_all }
        files = %w[config/initializers/rails_ai_admin.rb app/rails_ai_admin/admin_context.rb app/rails_ai_admin/admin_policy_adapter.rb].to_h do |path|
          [ File.basename(path, ".rb"), File.read(File.join(directory, path)) ]
        end
        return output, files
      end
    end
  end

  def test_rails_authentication_gets_a_working_context_and_the_full_access_policy
    Object.const_set(:Session, InstallSession)
    output, files = install({ full_access: true }, concern: true, routes: -> { resource :session, only: %i[new create destroy] })
    assert_equal <<~RUBY, files.fetch("rails_ai_admin")
      RailsAiAdmin.configure do |config|
        config.context_adapter = "AdminContext"
        # Grants everyone AdminContext admits everything the resources declare.
        config.authorization_adapter = "AdminPolicyAdapter"
        # The resources the admin serves. `bin/rails generate rails_ai_admin:resource`
        # adds to this list; nothing else is exposed.
        config.resources = []

        # Signed-out visitors go to the sign-in page; the header shows who is
        # signed in and a sign-out button.
        config.authentication_path = "/session/new"
        config.actor_label = :email_address
        config.sign_out_path = "/session"
      end
    RUBY
    assert_includes output, "AdminContext reads the Rails authentication session and admits each InstallUser whose admin? is true."
    refute_includes output, "has no admin? yet"
    assert_includes output, "AdminPolicyAdapter grants everything your resources declare"
    assert_includes output, "bin/rails generate rails_ai_admin:resource --all"

    Object.class_eval(files.fetch("admin_policy_adapter"))
    assert_equal RailsAiAdmin::Authorization::FullAccessAdapter, AdminPolicyAdapter.superclass
    assert_empty AdminPolicyAdapter.instance_methods(false), "every recipe stays a comment"

    Object.class_eval(files.fetch("admin_context"))
    session = InstallSession.create!(user: @user)
    controller = Controller.new(Request.new(Jar.new({ session_id: session.id }), {}))
    assert_nil AdminContext.new.resolve(controller), "closed until someone is an admin"
    assert_nil AdminContext.new.resolve(Controller.new(Request.new(Jar.new({}), {})))
    @user.update!(admin: true)
    context = AdminContext.new.resolve(controller)
    assert_equal @user, context.actor
    assert_equal "raa:tenant:AdminContext::SingleTenant:app", context.tenant_ref
    job = { actor_ref: context.actor_ref, tenant_ref: context.tenant_ref, security_version: context.security_version }
    assert_equal context.actor_ref, AdminContext.new.resolve_job(**job).actor_ref
    assert_nil AdminContext.new.resolve_job(**job, tenant_ref: "raa:tenant:Account:2")
    assert_nil AdminContext.new.resolve_job(**job, actor_ref: "raa:actor:Other:#{@user.id}")
    @user.update!(admin: false)
    assert_nil AdminContext.new.resolve_job(**job)
  end

  def test_devise_gets_a_context_for_its_scope
    routes = lambda do
      get "/users/sign_in", to: "sessions#new", as: :new_user_session
      delete "/users/sign_out", to: "sessions#destroy", as: :destroy_user_session
    end
    output, files = install({}, routes: routes) do |generator|
      generator.define_singleton_method(:devise_mappings) { { user: Mapping.new(:user, "InstallUser") } }
      generator.define_singleton_method(:devise_sign_out_via) { %i[delete] }
    end
    initializer = files.fetch("rails_ai_admin")
    assert_includes initializer, "  # This generated adapter denies every scope, action and field.\n"
    assert_includes initializer, "  config.authentication_path = \"/users/sign_in\"\n  config.actor_label = :email\n  config.sign_out_path = \"/users/sign_out\"\nend\n"
    assert_includes output, "AdminContext reads Devise's :user scope and admits each InstallUser whose admin? is true."
    assert_includes output, "AdminPolicyAdapter denies everything."
    assert_includes files.fetch("admin_policy_adapter"), "class AdminPolicyAdapter < RailsAiAdmin::Authorization::Adapter"

    Object.class_eval(files.fetch("admin_context"))
    controller = Controller.new(Request.new(nil, { "warden" => Warden.new(@user) }))
    assert_nil AdminContext.new.resolve(controller)
    assert_nil AdminContext.new.resolve(Controller.new(Request.new(nil, {})))
    @user.update!(admin: true)
    assert_equal @user, AdminContext.new.resolve(controller).actor
  end

  def test_an_admin_scope_admits_every_signed_in_account_and_other_verbs_are_kept
    routes = lambda do
      get "/admins/sign_in", to: "sessions#new", as: :new_admin_user_session
      get "/admins/sign_out", to: "sessions#destroy", as: :destroy_admin_user_session
    end
    output, files = install({}, routes: routes) do |generator|
      generator.define_singleton_method(:devise_mappings) { { admin_user: Mapping.new(:admin_user, "InstallUser") } }
      generator.define_singleton_method(:devise_sign_out_via) { %i[get] }
    end
    assert_includes files.fetch("rails_ai_admin"), "  config.sign_out_path = \"/admins/sign_out\"\n  config.sign_out_method = :get\nend\n"
    assert_includes output, "admits every signed-in InstallUser"
    Object.class_eval(files.fetch("admin_context"))
    assert_equal @user, AdminContext.new.resolve(Controller.new(Request.new(nil, { "warden" => Warden.new(@user) }))).actor
  end

  def test_devise_scope_names_containing_admin_do_not_bypass_the_predicate
    routes = -> { get "/members/sign_in", to: "sessions#new", as: :new_non_admin_session }
    output, files = install({}, routes: routes) do |generator|
      generator.define_singleton_method(:devise_mappings) { { non_admin: Mapping.new(:non_admin, "InstallUser") } }
      generator.define_singleton_method(:devise_sign_out_via) { %i[delete] }
    end
    assert_includes output, "whose admin? is true"
    Object.class_eval(files.fetch("admin_context"))
    assert_nil AdminContext.new.send(:context_for, @user)
    @user.update!(admin: true)
    assert AdminContext.new.send(:context_for, @user)
    @user.define_singleton_method(:active_for_authentication?) { false }
    assert_nil AdminContext.new.send(:context_for, @user), "locked or inactive Devise accounts stay closed"
  end

  def test_security_version_distinguishes_changes_within_one_second
    Object.const_set(:Session, InstallSession)
    _, files = install({}, concern: true, routes: -> { resource :session, only: %i[new create destroy] })
    Object.class_eval(files.fetch("admin_context"))
    @user.update!(admin: true)
    @user.updated_at = Time.utc(2026, 11, 13, 12, 0, 0, 100_000)
    first = AdminContext.new.send(:context_for, @user)
    @user.updated_at = Time.utc(2026, 11, 13, 12, 0, 0, 200_000)
    second = AdminContext.new.send(:context_for, @user)
    refute_equal first.security_version, second.security_version
  end

  def test_without_a_known_sign_in_system_the_context_stays_closed
    output, files = install({ full_access: true })
    assert_includes files.fetch("rails_ai_admin"), "  # config.authentication_path = \"/session/new\"\n"
    assert_includes output, "No Rails authentication or Devise setup was found, so AdminContext admits nobody."
    Object.class_eval(files.fetch("admin_context"))
    assert_nil AdminContext.new.resolve(nil)
    # A user model without an admin flag is called out.
    Object.send(:remove_const, :AdminContext)
    InstallUser.connection.remove_column(:install_users, :admin)
    InstallUser.reset_column_information
    Object.const_set(:Session, InstallSession)
    output, = install({}, concern: true, routes: -> { resource :session, only: %i[new create destroy] })
    assert_includes output, "InstallUser has no admin? yet, so nobody is admitted."
    assert_includes output, "bin/rails generate migration AddAdminToInstallUsers admin:boolean"
  end
end
