# frozen_string_literal: true

require "rails/generators"
require_relative "engine_mounts"
require_relative "../engine_migrations"

module RailsAiAdmin
  module Generators
    # Installs the engine tables, a mount and the host's two adapters. The
    # context is written for the sign-in system it finds (the Rails
    # authentication generator or Devise) and stays closed otherwise. The
    # policy denies everything unless --full-access asks for the preset.
    class InstallGenerator < Rails::Generators::Base
      include EngineMigrations
      source_root File.expand_path("templates", __dir__)

      # What the generator learned about the host's sign-in system.
      Auth = Struct.new(:kind, :model, :scope, :label, :sign_in, :sign_out, :sign_out_method, :all_admins, keyword_init: true)
      PATH = Configuration::INTERNAL_PATH

      class_option :full_access, type: :boolean, default: false,
        desc: "Write a policy that lets everyone the context admits use everything the resources declare"

      def initialize(args = [], options = {}, config = {})
        @host_application = config.fetch(:application) { Rails.application }
        super
      end

      def install
        unless @host_application && @host_application.root.realpath == Pathname.new(destination_root).realpath
          raise Rails::Generators::Error, "Run install inside the target Rails application so its actual routes can be checked. No files were changed."
        end
        # Rails draws routes lazily outside a server; the mount and sign-in
        # checks below read what is actually drawn.
        @host_application.reload_routes_unless_loaded if @host_application.respond_to?(:reload_routes_unless_loaded)
        mounts = EngineMounts.names(@host_application.routes)
        if mounts.empty? && @host_application.routes.named_routes.names.map(&:to_s).include?("rails_ai_admin")
          raise Rails::Generators::Error, "The rails_ai_admin route name belongs to another endpoint. Resolve the conflict before installation. No files were changed."
        end
        if mounts.any? && mounts != [ "rails_ai_admin" ]
          raise Rails::Generators::Error, "Use one RailsAiAdmin::Engine mount whose final helper is rails_ai_admin. Custom paths are supported; other aliases, name prefixes, dynamic parameters and multiple mounts require review. No files were changed."
        end
        %w[AdminContext AdminPolicyAdapter].each do |constant|
          target = File.join(destination_root, "app/rails_ai_admin/#{constant.underscore}.rb")
          if Object.const_defined?(constant) && !File.exist?(target)
            raise Rails::Generators::Error, "Constant #{constant} already exists outside the generated path"
          end
        end
        @auth = detect_authentication
        copy_engine_migrations("db/migrate")
        context = { rails: "admin_context_rails.rb.tt", devise: "admin_context_devise.rb.tt" }.fetch(@auth&.kind, "admin_context.rb")
        # Host files are written once. A later run (to copy new migrations)
        # keeps the registered resources and every reviewed edit, even with
        # --force.
        {
          "initializer.rb.tt" => "config/initializers/rails_ai_admin.rb",
          context => "app/rails_ai_admin/admin_context.rb",
          (options[:full_access] ? "admin_policy_adapter_full_access.rb" : "admin_policy_adapter.rb") => "app/rails_ai_admin/admin_policy_adapter.rb",
          "access_test.rb" => "test/rails_ai_admin/access_test.rb"
        }.each do |source, target|
          if File.exist?(File.join(destination_root, target))
            say_status :exist, target, :blue
          else
            template source, target
            (@written ||= []) << target
          end
        end
        route 'mount RailsAiAdmin::Engine => "/admin", as: :rails_ai_admin' if mounts.empty?
        next_steps
      end

      private

      def next_steps
        wrote = ->(path) { Array(@written).include?(path) }
        unless wrote.call("app/rails_ai_admin/admin_context.rb") && wrote.call("app/rails_ai_admin/admin_policy_adapter.rb")
          say "Existing host files were kept. Delete one to have it written again."
          return say("Next: bin/rails db:migrate, then bin/rails rails_ai_admin:doctor.")
        end
        if @auth
          who = @auth.all_admins ? "every signed-in #{@auth.model}" : "each #{@auth.model} whose admin? is true"
          say "AdminContext reads #{@auth.kind == :devise ? "Devise's :#{@auth.scope} scope" : 'the Rails authentication session'} and admits #{who}."
          unless @auth.all_admins || admin_flag?(@auth.model)
            say "#{@auth.model} has no admin? yet, so nobody is admitted. Add one, for example: bin/rails generate migration AddAdminTo#{@auth.model.pluralize} admin:boolean"
          end
        else
          say "No Rails authentication or Devise setup was found, so AdminContext admits nobody. Implement its resolve method for your sign-in system."
        end
        if options[:full_access]
          say "AdminPolicyAdapter grants everything your resources declare to everyone AdminContext admits. It applies no tenant condition or roles; narrow it in app/rails_ai_admin/admin_policy_adapter.rb."
        else
          say "AdminPolicyAdapter denies everything. Grant scopes, actions and fields there, or change its superclass to RailsAiAdmin::Authorization::FullAccessAdapter for trusted staff."
        end
        say "Next: bin/rails db:migrate, then bin/rails generate rails_ai_admin:resource --all (or name the models), then bin/rails rails_ai_admin:doctor."
        say "Guide: #{GUIDES}/_getting_started/quickstart.md"
      end

      def admin_flag?(model)
        klass = model.safe_constantize
        klass && (klass.method_defined?(:admin?) || klass.respond_to?(:column_names) && klass.column_names.include?("admin"))
      rescue ActiveRecord::ActiveRecordError
        false
      end

      # Devise first, because an app can carry both a Session model and Devise.
      def detect_authentication
        detect_devise || detect_rails_authentication
      rescue StandardError
        nil
      end

      def detect_devise
        mappings = devise_mappings
        return if mappings.empty?
        mapping = mappings[:user] || mappings.values.first
        scope = mapping.name.to_s
        model = mapping.class_name.to_s
        return unless scope.match?(/\A[a-z][a-z0-9_]*\z/) && model.match?(/\A[A-Z]\w*(?:::[A-Z]\w*)*\z/)
        sign_in = named_path("new_#{scope}_session")
        return unless sign_in
        via = devise_sign_out_via.find { |verb| %i[delete post get].include?(verb) }
        Auth.new(kind: :devise, model: model, scope: scope, label: "email", sign_in: sign_in,
          sign_out: via && named_path("destroy_#{scope}_session"), sign_out_method: via || :delete, all_admins: %w[admin admin_user].include?(scope))
      end

      def devise_mappings
        defined?(::Devise) && ::Devise.respond_to?(:mappings) ? ::Devise.mappings : {}
      end

      def devise_sign_out_via = Array(::Devise.sign_out_via).map(&:to_sym)

      # The Rails authentication generator: a Session model that belongs to a
      # user, the Authentication concern and a `resource :session` route.
      def detect_rails_authentication
        return unless File.exist?(File.join(destination_root, "app/controllers/concerns/authentication.rb"))
        session = "Session".safe_constantize
        return unless session.is_a?(Class) && session < ActiveRecord::Base
        user = session.reflect_on_association(:user)&.klass
        return unless user&.name&.match?(/\A[A-Z]\w*(?:::[A-Z]\w*)*\z/)
        sign_in = named_path("new_session")
        return unless sign_in
        label = user.column_names.include?("email_address") ? "email_address" : "id"
        Auth.new(kind: :rails, model: user.name, scope: nil, label: label, sign_in: sign_in,
          sign_out: named_path("session"), sign_out_method: :delete, all_admins: false)
      end

      # A fixed host path for a named route, or nil when it has none.
      def named_path(name)
        routes = @host_application.routes
        return unless routes.named_routes.names.map(&:to_s).include?(name)
        path = routes.url_helpers.public_send("#{name}_path")
        path if path.is_a?(String) && path.ascii_only? && path.match?(PATH)
      rescue StandardError
        nil
      end
    end
  end
end
