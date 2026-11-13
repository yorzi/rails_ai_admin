# frozen_string_literal: true

require "digest"

module RailsAiAdmin
  module Templates
    # Explicit public presentation paths. Revision changes track context/locals
    # compatibility even when the template bytes themselves do not change.
    class Catalog
      Entry = Data.define(:key, :path, :revision, :assigns, :locals)
      DEFINITIONS = {
        "layout" => [ "layouts/rails_ai_admin/application.html.erb", %i[context admin_csp_nonce], [] ],
        "status_layout" => [ "layouts/rails_ai_admin/status.html.erb", %i[admin_status], [] ],
        "status_page" => [ "rails_ai_admin/statuses/show.html.erb", %i[admin_status status_sign_in_path], [] ],
        "session_links" => [ "rails_ai_admin/shared/_session.html.erb", %i[context], [] ],
        "resource_navigation" => [ "rails_ai_admin/shared/_navigation.html.erb", [], %i[groups] ],
        "dashboard" => [ "rails_ai_admin/dashboard/index.html.erb", %i[context counts widgets], [] ],
        "audit_log" => [ "rails_ai_admin/audit/index.html.erb", %i[context log filters page actor_labels], [] ],
        "resource_import" => [ "rails_ai_admin/imports/new.html.erb", %i[context resource import report problem], [] ],
        "search" => [ "rails_ai_admin/search/index.html.erb", %i[context query sections], [] ],
        "resource_index" => [ "rails_ai_admin/resources/index.html.erb", %i[context resource page columns rows searchable selectable exportable importable sortable_fields list_scopes current_scope filter_fields omitted_rows], [] ],
        "resource_show" => [ "rails_ai_admin/resources/show.html.erb", %i[context resource record values fields operations association_panels], [] ],
        "resource_history" => [ "rails_ai_admin/resources/history.html.erb", %i[context resource record history actor_labels], [] ],
        "resource_associations" => [ "rails_ai_admin/resources/_associations.html.erb", [], %i[panels] ],
        "resource_new" => [ "rails_ai_admin/resources/new.html.erb", %i[context resource record operation intent_ref form_fields form_values form_plan errors failure_code needs_reload], [] ],
        "resource_edit" => [ "rails_ai_admin/resources/edit.html.erb", %i[context resource record operation intent_ref form_fields form_values form_plan errors failure_code needs_reload], [] ],
        "resource_form" => [ "rails_ai_admin/resources/form.html.erb", %i[context resource record operation intent_ref form_fields form_values form_plan errors failure_code needs_reload], [] ],
        "resource_destroy" => [ "rails_ai_admin/resources/confirm_destroy.html.erb", %i[context resource record intent_ref errors failure_code needs_reload], [] ],
        "form_recovery" => [ "rails_ai_admin/resources/_recovery.html.erb", [], [] ],
        "resource_errors" => [ "rails_ai_admin/resources/_errors.html.erb", %i[errors failure_code needs_reload], %i[form fields] ],
        "field_index" => [ "rails_ai_admin/fields/_index.html.erb", [], %i[field value text] ],
        "field_show" => [ "rails_ai_admin/fields/_show.html.erb", [], %i[field value text] ],
        "field_reference" => [ "rails_ai_admin/fields/_reference.html.erb", [], %i[field value reference] ],
        "field_form" => [ "rails_ai_admin/fields/_input.html.erb", [], %i[field form value input_options] ],
        "field_row" => [ "rails_ai_admin/fields/_row.html.erb", [], %i[form entry errors] ],
        "input_fields" => [ "rails_ai_admin/shared/_input_fields.html.erb", %i[resource], %i[form fields values errors plan] ],
        "operation_form" => [ "rails_ai_admin/operations/form.html.erb", %i[context resource record definition flow_id form_fields form_values errors failure_code needs_reload], [] ],
        "operation_confirmation" => [ "rails_ai_admin/operations/confirmation.html.erb", %i[context resource record definition flow_id proposal form_fields form_values wire_input], [] ],
        "operation_failure" => [ "rails_ai_admin/operations/failure.html.erb", %i[context resource failure_code], [] ],
        "collection_form" => [ "rails_ai_admin/collection_operations/new.html.erb", %i[context resource definition selection form_fields form_values errors failure_code], [] ],
        "collection_confirmation" => [ "rails_ai_admin/collection_operations/confirmation.html.erb", %i[context resource definition proposal wire_input], [] ],
        "collection_failure" => [ "rails_ai_admin/collection_operations/failure.html.erb", %i[context resource failure_code uncertain_job_ref], [] ],
        "job_index" => [ "rails_ai_admin/collection_jobs/index.html.erb", %i[context jobs], [] ],
        "job_show" => [ "rails_ai_admin/collection_jobs/show.html.erb", %i[context resource job], [] ],
        "selection" => [ "rails_ai_admin/selections/show.html.erb", %i[context resource selection operations deletable], [] ],
        "selection_destroy" => [ "rails_ai_admin/selections/confirm_destroy.html.erb", %i[context resource selection deletable skipped], [] ],
        "selection_destroy_result" => [ "rails_ai_admin/selections/destroyed.html.erb", %i[context resource selection deleted skipped failed], [] ]
      }.freeze
      ENTRIES = DEFINITIONS.map do |key, (path, assigns, locals)|
        navigation = %w[layout resource_index resource_show resource_history resource_new resource_edit resource_form resource_destroy operation_form operation_confirmation operation_failure collection_form collection_confirmation collection_failure job_show selection selection_destroy selection_destroy_result].include?(key)
        assigns += [ :list_navigation ] if navigation
        revision = if key == "layout"
          4 # page titles, environment label and the session_links slot (RAA-024)
        elsif key == "dashboard"
          4 # counts, widgets
        elsif key == "resource_index"
          8 # exportable, importable (CSV)
        elsif key == "resource_show"
          3
        elsif %w[resource_new resource_edit resource_form].include?(key)
          5 # intent_ref replaces intent (ADR 0025)
        elsif %w[resource_destroy resource_errors].include?(key)
          3 # intent_ref; outcome sentences and RESTRICTED
        elsif navigation || %w[input_fields field_form].include?(key)
          2
        else
          1
        end
        Entry.new(key.freeze, path.freeze, revision, assigns.freeze, locals.freeze)
      end.freeze

      def initialize(source_root: Engine.root.join("app/views"), entries: ENTRIES)
        @source_root = Pathname.new(source_root).expand_path
        @entries = entries.freeze
      end

      def entries = @entries
      def fetch(key) = entries.find { |entry| entry.key == key.to_s } || raise(ConfigurationError, "Unknown override key; use --list")
      def for_path(path) = entries.find { |entry| entry.path == path }
      def source_path(entry) = @source_root.join(entry.path)
      def source_digest(entry) = Digest::SHA256.file(source_path(entry)).hexdigest
    end
  end
end
