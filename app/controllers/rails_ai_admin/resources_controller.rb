# frozen_string_literal: true

module RailsAiAdmin
  # Conventional pages use the same operation runner as other trusted adapters.
  class ResourcesController < ApplicationController
    before_action :resolve_resource

    def index
      raw = params.to_unsafe_h.slice(*Navigation::ListState::KEYS)
      @list_navigation = Navigation::ListState.new(@access, raw, strict: true)
      if return_state_discarded?
        redirect_to list_return_path, status: :see_other, notice: t("rails_ai_admin.resources.index.settings_restored")
        return
      end
      # A native filter form submits every input; share only the canonical
      # nonblank conditions. This changes no grant and adds no notice.
      if raw.key?("filter") && raw["filter"] != navigation_state["filter"]
        redirect_to list_return_path, status: :see_other
        return
      end
      @page = Queries::List.new(@context, @resource).call(search: navigation_state["q"], sort: navigation_state["sort"], direction: navigation_state.fetch("direction", "asc"), page: navigation_state.fetch("page", "1"), recover_empty_page: true, scope: navigation_state["scope"], filters: navigation_state["filter"])
      if @page.number != navigation_state.fetch("page", "1").to_i
        @list_navigation = Navigation::ListState.new(@access, navigation_state.merge("page" => @page.number.to_s))
        redirect_to list_return_path, status: :see_other, notice: t("rails_ai_admin.resources.index.page_empty")
        return
      end
      @sortable_fields = @access.fields(:sort)
      @list_scopes = @access.named_scopes
      @filter_fields = @access.fields(:filter)
      @current_scope = @page.scope
      @columns = @resource.index.order(@access.fields(:read, view: :index))
      computed = @columns.map(&:name) | [ @resource.title ]
      # A record inside the policy scope whose own show check fails is left out
      # of the page, like an unavailable reference, instead of failing the
      # whole list (RAA-001). The notice says rows were left out, never which.
      @rows = @page.records.filter_map do |record|
        values = @access.project(record, view: :index, only: computed)
        { id: record.id, label: record_label(@resource, record, values: values, view: :index), values: values,
          editable: allowed_action?(@resource, :update, record) }
      rescue AccessDenied
        @omitted_rows = true
        nil
      end
      # One target query per reference column instead of one per row.
      @columns.select { |field| field.scalar_type == :belongs_to }.each do |field|
        admin_associations.prime(field, @rows.filter_map { |row| row[:values][field.name.to_s] })
      end
      @searchable = @access.fields(:search).any?
      @omitted_rows ||= false
      @selectable = begin
        @access.authorize_selection!
      rescue AccessDenied
        false
      end
      # Offered when deleting is on; each record's own grant is checked on review.
      @bulk_destroy = @selectable && @resource.action_enabled?(:destroy)
      @bulk_operations = @selectable ? granted_collection_operations(@resource, @access) : []
      @importable = begin
        @access.authorize_import!
      rescue AccessDenied
        false
      end
      @exportable = begin
        @access.authorize_export!
      rescue AccessDenied
        false
      end
    end

    def show
      @record = @access.find!(params[:id])
      @values = @access.project(@record, view: :show)
      @fields = @access.fields(:read, @record, view: :show)
      @association_panels = Presentation::AssociationPanel.build(@context, @resource, @record)
      @operations = RailsAiAdmin.operation_registry.custom(@resource).select { |definition| definition.scope == :member }.select do |definition|
        @access.authorize!(definition.key, @record)
        definition.fields(@access, @record)
        true
      rescue AccessDenied
        false
      end
    end

    # Who changed this record, when and which fields, newest first.
    def history
      @record = @access.find!(params[:id])
      before = params[:before]
      raise AccessDenied, "INVALID_QUERY" unless before.nil? || before.is_a?(String)
      @history = Presentation::History.new(@access, @record).page(before: before)
      @actor_labels = actor_labels(@history.entries.map(&:actor_ref).uniq)
    end

    def new
      prepare_form(:create)
    end

    def edit
      prepare_form(:update)
    end

    def recover_form
      response.headers["Vary"] = [ response.headers["Vary"], "Cookie", "X-RailsAiAdmin-Recovery-Intent", "X-RailsAiAdmin-Return-State" ].compact.join(", ")
      @intent_ref = request.headers["X-RailsAiAdmin-Recovery-Intent"]
      session = runner.resume_form(context: @context, resource: @resource, intent_ref: @intent_ref)
      @intent, @record = session.intent, session.record
      @operation = @intent.operation.to_sym
      build_form_plan(@operation)
      @errors = {}
      render @operation == :create ? :new : :edit
      response.headers["X-RailsAiAdmin-Form-Recovery"] = "ready"
    end

    def confirm_destroy
      prepare_form(:destroy)
    end

    def create = submit(:create)
    def update = submit(:update)
    def destroy = submit(:destroy)

    private

    def resolve_resource
      @resource = RailsAiAdmin.registry.fetch(params[:resource])
      @access = Authorization::Access.new(@context, @resource)
      raise AccessDenied if params.key?(:id) && !@access.canonical_id?(params[:id])
      resolve_list_navigation unless action_name == "index"
    end

    def runner
      @runner ||= Operations::Runner.new
    end

    def prepare_form(operation)
      @operation = operation
      @record = operation == :create ? @access.relation.new : @access.find!(params[:id], action: operation)
      @access.authorize!(operation, @record)
      build_form_plan(operation, operation == :create ? prefill_values : nil) unless operation == :destroy
      @errors = {}
      # GET stays read-only: the form carries a signed reference that becomes
      # an intent on submit (RAA-005, ADR 0025).
      @intent_ref = runner.issue_form_intent(context: @context, resource: @resource, operation: operation,
        target_id: operation == :create ? nil : @record.id, expected_version: operation == :create ? nil : RecordVersion.of(@record)).ref
      render operation == :destroy ? :confirm_destroy : operation == :create ? :new : :edit
    end

    # prefill[<belongs_to field>]=<key> starts a new record pointing at a
    # parent, as the "Add" link of an association panel does. Only writable
    # references to targets the actor can see are taken; anything else is
    # ignored, and the person still submits the form.
    def prefill_values
      raw = params[:prefill]
      return nil unless raw.is_a?(ActionController::Parameters)
      raw = raw.to_unsafe_h
      references = @access.fields(:write, @record, operation: :create).select { |field| field.scalar_type == :belongs_to }
      resolver = Fields::Association.new(@context, @resource)
      references.each_with_object({}) do |field, values|
        value = raw[field.name.to_s]
        next unless value.is_a?(String)
        key = field.coerce(value)
        values[field.name.to_s] = key if key && resolver.admissible?(field, key)
      rescue ArgumentError
        next
      end
    end

    def submit(operation)
      input = operation == :destroy ? {} : submitted_input
      @intent_ref = params[:intent_ref]
      intent_id = runner.materialize_form_intent(context: @context, reference: @intent_ref)
      upload_files(operation, input) unless operation == :destroy
      result = runner.execute(context: @context, intent_ref: intent_id, input: input,
        human_confirmed: true, origin: :ui,
        binding: { resource_key: @resource.key, operation: operation, target_id: params[:id] })
      discard_uploads unless result.success?
      if result.success?
        target = operation == :destroy ? list_return_path : resource_path(resource: @resource.key, id: result.record_id, **navigation_params)
        redirect_to target, status: :see_other, notice: result.warning ? t("rails_ai_admin.resources.saved_with_warning", operation: intent_id) : t("rails_ai_admin.resources.saved")
      elsif result.code == "NOT_FOUND"
        raise AccessDenied
      else
        @operation = operation
        @record = operation == :create ? @access.relation.new : @access.find!(params[:id], action: operation)
        @access.authorize!(operation, @record)
        @intent = OperationRun.find_by!(id: intent_id, actor_ref: @context.actor_ref, tenant_ref: @context.tenant_ref)
        build_form_plan(operation, input) unless operation == :destroy
        names = operation == :destroy ? [] : @form_fields.map { |field| field.name.to_s }
        @errors = result.errors.slice("base", *names)
        @errors["base"] ||= [ t("rails_ai_admin.resources.form.inputs_unavailable") ] if (result.errors.keys - [ "base" ] - names).any?
        @failure_code = result.code
        # A restricted delete can succeed once the references are gone.
        @needs_reload = !%w[VALIDATION_FAILED RESTRICTED].include?(result.code)
        render operation == :destroy ? :confirm_destroy : operation == :create ? :new : :edit,
          status: %w[VALIDATION_FAILED RESTRICTED].include?(result.code) ? :unprocessable_content : :conflict
      end
    rescue ActiveRecord::RecordNotFound
      raise AccessDenied
    end

    # A chosen file becomes a new blob before the write, and only for a file
    # field the actor may write now. Pages never pass blob ids: a text value in
    # a file slot is refused. remove_files[] clears a file that is not required.
    def upload_files(operation, input)
      @uploaded_blobs = []
      record = operation == :create ? @access.relation.new : @access.find!(params[:id], action: operation)
      writable = @access.fields(:write, record, operation: operation)
      upload_lists(writable.select { |field| field.scalar_type == :files }, input)
      files = writable.select { |field| field.scalar_type == :file }.index_by { |field| field.name.to_s }
      input.each_key do |name|
        value = input[name]
        next if writable.any? { |field| field.scalar_type == :files && field.name.to_s == name }
        next unless files.key?(name) || value.is_a?(ActionDispatch::Http::UploadedFile)
        field = files[name] || raise(AccessDenied, "INVALID_QUERY")
        if value == ""
          input.delete(name)
        elsif !value.is_a?(ActionDispatch::Http::UploadedFile)
          raise AccessDenied, "INVALID_QUERY"
        elsif value.size > field.options[:max_size]
          input[name] = Fields::RejectedUpload.new("too_large", field.options[:max_size])
        else
          input[name] = store_upload(value)
        end
      end
      removals = params[:remove_files]
      return if removals.nil?
      raise AccessDenied, "INVALID_QUERY" unless removals.is_a?(Array) && removals.size <= files.size && removals.all? { |name| name.is_a?(String) && files.key?(name) }
      removals.each { |name| input[name] = nil unless input.key?(name) }
    end

    def store_upload(value)
      raise ConfigurationError, "file fields need Active Storage" unless defined?(::ActiveStorage::Blob)
      blob = ::ActiveStorage::Blob.create_and_upload!(io: value, filename: value.original_filename.presence || "upload",
        content_type: value.content_type, identify: true)
      @uploaded_blobs << blob
      blob.signed_id
    end

    # files fields: record[photos][] carries new uploads and
    # remove_attachments[photos][] the attachment ids to remove.
    def upload_lists(fields, input)
      removals = params[:remove_attachments]
      removals = removals.to_unsafe_h if removals.is_a?(ActionController::Parameters)
      raise AccessDenied, "INVALID_QUERY" unless removals.nil? || removals.is_a?(Hash)
      removals ||= {}
      raise AccessDenied, "INVALID_QUERY" unless (removals.keys - fields.map { |field| field.name.to_s }).empty?
      fields.each do |field|
        name = field.name.to_s
        uploads = input.key?(name) ? input[name] : []
        remove = removals.fetch(name, [])
        raise AccessDenied, "INVALID_QUERY" unless uploads.is_a?(Array) && remove.is_a?(Array) && remove.all? { |id| id.is_a?(String) }
        uploads = uploads.reject { |value| value == "" }
        raise AccessDenied, "INVALID_QUERY" unless uploads.all? { |value| value.is_a?(ActionDispatch::Http::UploadedFile) }
        added = uploads.map { |value| value.size > field.options[:max_size] ? Fields::RejectedUpload.new("too_large", field.options[:max_size]) : store_upload(value) }
        if added.empty? && remove.empty?
          input.delete(name)
        else
          input[name] = { "add" => added, "remove" => remove }
        end
      end
    end

    # A refused write keeps no new upload; the person chooses the file again.
    def discard_uploads
      Array(@uploaded_blobs).each { |blob| blob.purge_later unless blob.attachments.exists? }
    end

    def submitted_input
      value = params[:record]
      raise AccessDenied, "INVALID_QUERY" unless value.nil? || value.is_a?(ActionController::Parameters)
      value.is_a?(ActionController::Parameters) ? value.to_unsafe_h : {}
    end

    def build_form_plan(operation, input = nil)
      view = operation == :create ? :create : :edit
      @form_fields = @access.fields(:write, @record, operation: operation)
      readable_values = begin
        @access.project(@record, view: view)
      rescue AccessDenied
        {}
      end
      names = @form_fields.map { |field| field.name.to_s }
      @form_values = readable_values.slice(*names)
      if input.is_a?(Hash)
        # A refused file is chosen again; the form keeps showing the stored one.
        files = @form_fields.select { |field| Field::FILE_TYPES.include?(field.scalar_type) }.map { |field| field.name.to_s }
        @form_values.merge!(input.stringify_keys.slice(*(names - files)).reject { |_, value| value.is_a?(Hash) || value.is_a?(Array) })
      end
      readonly_fields = @access.fields(:read, @record, view: view).select { |field| readable_values.key?(field.name.to_s) && !names.include?(field.name.to_s) }
      readonly_values = readable_values.slice(*readonly_fields.map { |field| field.name.to_s })
      @form_plan = Forms::Plan.new(fields: @form_fields, values: @form_values, readonly_fields: readonly_fields, readonly_values: readonly_values, order: @resource.fields)
    end
  end
end
