# frozen_string_literal: true

module RailsAiAdmin
  # Resolves fresh host authority for every request without altering host classes.
  class ApplicationController < ActionController::Base
    # Routing metadata is useful; arbitrary inputs and search text are not logs.
    LOG_FILTER = /\A(?!(?:controller|action|resource|id|format)\z)/
    protect_from_forgery with: :exception
    wrap_parameters false
    layout "rails_ai_admin/application"
    helper RailsAiAdmin::FieldsHelper
    helper RailsAiAdmin::NavigationHelper
    helper RailsAiAdmin::FiltersHelper
    helper RailsAiAdmin::ToolViewsHelper
    helper RailsAiAdmin::HistoryHelper
    helper RailsAiAdmin::DashboardHelper
    prepend_before_action :secure_headers
    before_action :authenticate_admin
    after_action :notice_discarded_list_settings
    helper_method :resource_navigation, :admin_csp_nonce, :list_page_path, :encoded_return_state, :navigation_state, :navigation_params, :list_return_path, :list_return_label, :return_state_discarded?, :return_navigation_fields, :list_state_fields, :visible_resources, :allowed_action?, :record_label, :parent_return, :parent_return_params, :parent_return_fields, :collection_jobs_available?, :admin_associations, :assistant_available?, :searchable_resources, :audit_log_available?, :actor_labels, :assistant_for?

    rescue_from AccessDenied, with: :deny_access
    rescue_from ConfigurationError do
      admin_status(:unavailable)
    end
    rescue_from ActionController::InvalidAuthenticityToken do
      mark_form_recovery
      admin_status(:invalid_request)
    end

    protected

    # Layouts loading the prebuilt Turbo bundle need this nonce in csp-nonce meta.
    def admin_csp_nonce
      raise ConfigurationError, "Admin security headers have not been prepared" unless @admin_csp_nonce.is_a?(String) && @admin_csp_nonce.present?
      String.new(@admin_csp_nonce).freeze
    end

    # Like Rails render, this does not halt an action. Callers must return when
    # selecting a status instead of continuing toward business work.
    def admin_status(kind)
      @admin_status = Presentation::Status.fetch(kind)
      response.headers.delete("X-RailsAiAdmin-Form-Recovery") if response.headers["X-RailsAiAdmin-Form-Recovery"] == "ready"
      @status_sign_in_path = nil
      if @admin_status.kind == "authentication_required"
        path = RailsAiAdmin.configuration.authentication_path
        @status_sign_in_path = String.new(path).freeze if path.is_a?(String) && path.valid_encoding? && path.ascii_only? && path.match?(Configuration::INTERNAL_PATH)
      end
      if request.format.html? || request.format.turbo_stream?
        begin
          render template: "rails_ai_admin/statuses/show", layout: "rails_ai_admin/status", formats: [ :html ],
            content_type: "text/html", status: @admin_status.http_status
        rescue StandardError
          self.response_body = nil
          render plain: @admin_status.message, content_type: "text/plain", status: @admin_status.http_status
        end
      else
        render plain: @admin_status.message, status: @admin_status.http_status
      end
    end

    private

    def process_action(*)
      filters = Array(request.get_header("action_dispatch.parameter_filter")) + [ LOG_FILTER ]
      request.set_header("action_dispatch.parameter_filter", filters)
      super
    end

    def secure_headers
      @admin_csp_nonce = SecureRandom.base64(24)
      response.headers["Cache-Control"] = "no-store, private"
      response.headers["Content-Security-Policy"] = "default-src 'self'; script-src 'self'; style-src 'self' 'nonce-#{@admin_csp_nonce}'; img-src 'self' data:; connect-src 'self'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'; object-src 'none'"
      response.headers["X-Content-Type-Options"] = "nosniff"
      response.headers["Referrer-Policy"] = "same-origin"
    end

    def authenticate_admin
      name = RailsAiAdmin.configuration.context_adapter
      @context = name&.constantize&.new&.resolve(self)
      raise AccessDenied, "UNAUTHENTICATED" unless @context.is_a?(Context)
    end

    def deny_access(error)
      status = Presentation::Status.for_code(error.code)
      if status.kind == "authentication_required" && (target = sign_in_redirect)
        return redirect_to(target, status: :see_other)
      end
      mark_form_recovery if status.kind == "authentication_required"
      admin_status(status.kind)
    end

    # A plain page visit by a signed-out person goes to the host's sign-in
    # page with the requested path (RAA-024). Form submissions, recovery,
    # frames and non-HTML requests keep the 401, so no open form is lost. The
    # query string is left out: it can carry search text. The host must still
    # validate return_to before redirecting to it.
    def sign_in_redirect
      path = RailsAiAdmin.configuration.authentication_path
      return unless path.is_a?(String) && path.match?(Configuration::INTERNAL_PATH)
      return unless request.get? && request.format.html? && !request.xhr?
      return if request.headers["Turbo-Frame"] || request.headers["X-RailsAiAdmin-Recovery-Intent"]
      requested = request.path
      return path unless requested.is_a?(String) && requested.match?(%r{\A/(?![/\\])[^\s]*\z}) && requested.length <= 2000
      "#{path}?#{{ return_to: requested }.to_query}"
    end

    def mark_form_recovery
      if is_a?(ResourcesController) && %w[create update].include?(action_name)
        response.headers["X-RailsAiAdmin-Form-Recovery"] = "session"
      end
    end

    def resolve_list_navigation
      raw = params[:return_to]
      raw = raw.to_unsafe_h if raw.is_a?(ActionController::Parameters)
      access = Authorization::Access.new(@context, @resource)
      @list_navigation = if action_name == "recover_form"
        Navigation::ListState.from_header(access, request.headers["X-RailsAiAdmin-Return-State"])
      else
        Navigation::ListState.new(access, raw)
      end
    end

    def encoded_return_state = @list_navigation&.encoded || ""
    def navigation_state = @list_navigation&.state || {}
    def navigation_params = navigation_state.empty? ? {} : { return_to: navigation_state }
    def return_state_discarded? = @list_navigation&.discarded? == true

    def list_return_path
      @list_navigation&.index_allowed? ? resources_path(resource: @resource.key, **navigation_state.symbolize_keys) : root_path
    end

    def list_page_path(page)
      raise ConfigurationError, "Invalid list page" unless page.is_a?(Integer) && (1..1000).cover?(page)
      state = page == 1 ? navigation_state.except("page") : navigation_state.merge("page" => page.to_s)
      resources_path(resource: @resource.key, **state.symbolize_keys)
    end

    def list_return_label = @list_navigation&.index_allowed? ? @resource.label : t("rails_ai_admin.layout.administration")

    def return_navigation_fields
      helpers.safe_join(Navigation::ListState.form_pairs(navigation_state, "return_to").map { |name, value| helpers.hidden_field_tag(name, value, id: nil) })
    end

    # Hidden inputs that keep selected list settings in another GET list form.
    def list_state_fields(*keys)
      helpers.safe_join(Navigation::ListState.form_pairs(navigation_state.slice(*keys)).map { |name, value| helpers.hidden_field_tag(name, value, id: nil) })
    end

    def notice_discarded_list_settings
      return unless response.redirect? && return_state_discarded?
      message = t("rails_ai_admin.layout.settings_unavailable")
      flash[:notice] = [ flash[:notice], message ].compact.join(" ") unless flash[:notice].to_s.include?(message)
    end

    # Request-only memoization; no menu/grant snapshot survives authentication.
    def resource_navigation
      @resource_navigation ||= Navigation::Menu.build(context: @context,
        resources: RailsAiAdmin.registry.resources, current_key: @resource&.key)
    end

    def visible_resources
      RailsAiAdmin.registry.resources.select do |resource|
        Authorization::Access.new(@context, resource).authorize!(:index)
      rescue AccessDenied
        false
      end
    end

    # Resources in the menu that this actor may list and search, for the
    # header search box. Request-local; no grant survives the request.
    def searchable_resources
      @searchable_resources ||= RailsAiAdmin.registry.resources.select do |resource|
        next false if resource.navigation.hidden
        access = Authorization::Access.new(@context, resource)
        access.authorize!(:index)
        access.fields(:search).any?
      rescue AccessDenied
        false
      end
    end

    # back[resource] and back[id] name the parent record a child form was
    # opened from, so saving or cancelling returns there. It is a hint like
    # return_to: a registered resource and a canonical id, never authority;
    # the parent page checks its own grants when it is shown.
    ParentReturn = Data.define(:resource, :id)
    def parent_return
      return @parent_return if defined?(@parent_return)
      raw = params[:back]
      raw = raw.to_unsafe_h if raw.is_a?(ActionController::Parameters)
      @parent_return = if raw.is_a?(Hash) && raw.keys.sort == %w[id resource] && raw.values.all?(String)
        resource = RailsAiAdmin.registry.resources.find { |candidate| candidate.key.to_s == raw["resource"] }
        resource && Authorization::Access.new(@context, resource).canonical_id?(raw["id"]) ? ParentReturn.new(resource, raw["id"].dup.freeze) : nil
      end
    end

    def parent_return_params = parent_return ? { back: { resource: parent_return.resource.key.to_s, id: parent_return.id } } : {}

    def parent_return_fields
      return "".html_safe unless parent_return
      helpers.safe_join([ helpers.hidden_field_tag("back[resource]", parent_return.resource.key.to_s, id: nil), helpers.hidden_field_tag("back[id]", parent_return.id, id: nil) ])
    end

    # The parent page when the actor may still see that record, else nil.
    def parent_return_path
      return unless parent_return
      Authorization::Access.new(@context, parent_return.resource).find!(parent_return.id)
      resource_path(resource: parent_return.resource.key, id: parent_return.id)
    rescue AccessDenied
      nil
    end
    helper_method :parent_return_path

    # Collection operations the actor may start now over a selection.
    def granted_collection_operations(resource, access)
      RailsAiAdmin.operation_registry.custom(resource).select do |definition|
        next false unless definition.scope == :collection
        access.authorize!(definition.key)
        definition.fields(access, nil)
        true
      rescue AccessDenied
        false
      end
    end

    def allowed_action?(resource, action, record = nil)
      Authorization::Access.new(@context, resource).authorize!(action, record)
    rescue AccessDenied
      false
    end

    # Whether this page may offer "Ask the assistant" for a resource.
    def assistant_for?(resource)
      return false unless assistant_available?
      Authorization::Access.new(@context, resource).authorize_assistant!
    rescue AccessDenied
      false
    end

    def audit_log_available?
      return @audit_log_available unless @audit_log_available.nil?
      @audit_log_available = RailsAiAdmin.registry.resources.any? do |resource|
        Authorization::Access.new(@context, resource).authorize_audit_log!
      rescue AccessDenied
        false
      end
    end

    def collection_jobs_available?
      RailsAiAdmin.registry.resources.any? do |resource|
        RailsAiAdmin.operation_registry.custom(resource).any? do |definition|
          next false unless definition.scope == :collection
          Authorization::Access.new(@context, resource).authorize_receipt!(definition.key, nil)
        rescue AccessDenied
          false
        end
      end
    end

    # The menu link follows the same grant as the assistant pages.
    def assistant_available?
      return false unless RailsAiAdmin.configuration.assistant
      require "rails_ai_admin/assistant"
      @assistant_available = Assistant.available?(@context) if @assistant_available.nil?
      @assistant_available
    end

    # Request-local reference cache. Each target is read through its own
    # resource policy; nothing is shared across requests or actors.
    def admin_associations
      @admin_associations ||= Fields::Association.new(@context, @resource)
    end

    # Display names for stored actor references. The context adapter may
    # answer actor_labels(context:, actor_refs:) with a Hash; otherwise a
    # reference reads as "User #42".
    def actor_labels(refs)
      adapter = RailsAiAdmin.configuration.context_adapter&.constantize&.new
      given = adapter.respond_to?(:actor_labels) ? adapter.actor_labels(context: @context, actor_refs: refs) : {}
      given = {} unless given.is_a?(Hash)
      refs.to_h do |ref|
        label = given[ref]
        label = nil unless label.is_a?(String) && label.valid_encoding? && label.length.between?(1, 200)
        [ ref, label || default_actor_label(ref) ]
      end
    end

    def default_actor_label(ref)
      _, _, kind, id = ref.to_s.split(":", 4)
      kind && id ? "#{kind.demodulize.titleize} ##{id}" : ref.to_s
    end

    def record_label(resource, record, values: nil, view: :show)
      Authorization::Access.new(@context, resource).record_label(record, values: values, view: view)
    end
  end
end
