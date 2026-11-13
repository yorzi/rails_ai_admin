# frozen_string_literal: true

require "rails/generators"
require "rails_ai_admin/schema_suggestions"

module RailsAiAdmin
  module Generators
    # Writes explicit, editable resource files from schema metadata and adds
    # them to config.resources. It never reads a record. Sensitive, tenant and
    # internal columns are left out; whether anyone may use a declared field is
    # still the policy adapter's decision.
    class ResourceGenerator < Rails::Generators::Base
      FIELD = /\A([a-z][a-z0-9_]*)(?::([a-z_]+))?\z/
      MODEL = /\A[A-Z][A-Za-z0-9]*(?:::[A-Z][A-Za-z0-9]*)*\z/
      NAME = /\A[a-z][a-z0-9_]*\z/
      INITIALIZER = "config/initializers/rails_ai_admin.rb"
      RESOURCES = /^(?<indent>[ \t]*)config\.resources\s*=\s*(?<list>%w\[[^\]]*\]|\[[^\]]*\])/
      # The most columns a generated list declares, the id included.
      LISTED = 7
      SORTABLE = %i[integer decimal date datetime].freeze
      FILTERABLE = %i[enum boolean belongs_to].freeze
      UNLISTED = %i[textarea json rich_text files].freeze

      Plan = Struct.new(:model_name, :model, :constant, :key, :target, :available, :enabled, :rest, :omitted, :title, :panels, :hints, keyword_init: true) do
        # Saving needs a version column to detect an edit made in between.
        def versioned? = !model.nil? && RecordVersion.supported?(model)
        def unavailable? = !available
      end

      desc "Writes a resource for each named model (or every model with --all) and registers it."
      argument :models, type: :array, default: [], banner: "Model [Model ...]"
      class_option :all, type: :boolean, default: false,
        desc: "Also write a resource for every model in app/models that has none yet"
      class_option :fields, type: :array, default: [], banner: "name[:type] ...",
        desc: "For one model: enable only these schema-suggested fields; the rest stay commented"
      class_option :readonly, type: :boolean, default: false,
        desc: "Declare the resources readonly (no create, update or delete)"
      class_option :register, type: :boolean, default: true,
        desc: "Add the resources to config.resources in #{INITIALIZER}"

      def create_resources
        @plans = plans
        return say("Every model in app/models already has a resource.") if @plans.empty?
        keys = resource_keys(@plans)
        @plans.each { |plan| resolve_references(plan, keys) }
        @plans.each { |plan| enrich(plan) }
        @plans.each { |plan| plan.panels = panels(plan, keys) }
        @plans.each { |plan| create_file plan.target, source(plan) }
      end

      def register_resources
        return if @plans.empty?
        # A resource whose model has no schema yet stays out until it is reviewed.
        @registrable = @plans.select(&:available)
        @registered = options[:register] && @registrable.any? && register(@registrable.map(&:constant))
      end

      def report
        return if @plans.empty?
        @plans.each do |plan|
          mode = readonly?(plan) ? "readonly " : ""
          say "#{plan.constant}: enabled #{mode}fields: #{[ 'id', *plan.enabled.map(&:name) ].join(', ')}."
          if plan.available && !plan.versioned? && !options[:readonly]
            say "  #{plan.model_name} has no updated_at or lock_version column, so it is readonly here. Add timestamps to edit it in the admin."
          end
        end
        names = @registrable.map { |plan| "\"#{plan.constant}\"" }.join(", ")
        if @registered
          say "Registered in #{INITIALIZER}."
        elsif @registrable.any?
          say "Add #{names} to config.resources in #{INITIALIZER}."
        end
        if full_access?
          say "Your policy grants every declared field, so review each file: what it declares is what the admin shows and edits."
        else
          say "Grant the fields in your policy adapter (read, write, search, sort and filter lists), or use RailsAiAdmin::Authorization::FullAccessAdapter."
        end
      end

      private

      def plans
        requested = models.map { |name| name.to_s.camelize }
        requested.each do |name|
          raise Rails::Generators::Error, "Use a model class name such as Post or Billing::Invoice, not #{name.inspect}" unless name.match?(MODEL)
        end
        if options[:fields].any? && (requested.size != 1 || options[:all])
          raise Rails::Generators::Error, "--fields applies to one named model"
        end
        raise Rails::Generators::Error, "Name at least one model, or pass --all" if requested.empty? && !options[:all]
        raise Rails::Generators::Error, "A model is listed twice" unless requested.uniq.size == requested.size
        names = requested + (options[:all] ? discovered_models - requested : [])
        result = names.map { |name| plan(name, explicit: requested.include?(name)) }.compact
        collision = result.group_by(&:key).find { |_, entries| entries.size > 1 }
        if collision
          raise Rails::Generators::Error, "Models #{collision.last.map(&:model_name).join(', ')} share resource key #{collision.first}; generate them separately and choose distinct keys"
        end
        result
      end

      # Models defined under app/models with a table and a single primary key.
      # Single-table subclasses share their base model's resource.
      def discovered_models
        Rails.application.eager_load! if Rails.application
        root = model_source_root
        ActiveRecord::Base.descendants.select do |model|
          next false if model.name.blank? || !model.name.match?(MODEL) || model.abstract_class? || model.base_class != model
          location = Object.const_source_location(model.name)&.first
          next false unless location && File.expand_path(location).start_with?(root) && model.table_exists? && model.primary_key.is_a?(String)
          next true unless sign_in_session?(model)
          say "Skipped Session: sign-in sessions are not added by --all. Name the model to write its resource."
          false
        rescue ActiveRecord::ActiveRecordError
          false
        end.map(&:name).sort
      end

      # Sign-in sessions from the Rails authentication generator. Editing one
      # can move it to another user, so --all leaves it to an explicit request.
      def sign_in_session?(model)
        model.name == "Session" && (%w[ip_address user_agent] - model.column_names).empty?
      end

      def model_source_root = File.join(File.expand_path(destination_root), "app/models/")

      def plan(name, explicit:)
        constant = "#{name}Admin"
        key = self.class.resource_key(name)
        target = "app/rails_ai_admin/#{name.underscore}_admin.rb"
        exists = File.exist?(File.join(destination_root, target))
        registered = RailsAiAdmin.registry.resources.find { |resource| resource.model == name }
        unless explicit
          # --all fills gaps; it never rewrites or doubles a resource.
          return if exists || registered || Registry::RESERVED.include?(key) || constant.safe_constantize ||
            RailsAiAdmin.registry.resources.any? { |resource| resource.key.to_s == key }
        end
        raise Rails::Generators::Error, "Reserved resource key #{key}; write this resource by hand with another key" if Registry::RESERVED.include?(key)
        raise Rails::Generators::Error, "Constant #{constant} already exists" if constant.safe_constantize && !exists
        taken = RailsAiAdmin.registry.resources.find { |resource| resource.key.to_s == key && resource.model != name }
        raise Rails::Generators::Error, "Resource key #{key} already belongs to #{taken.name}" if taken && !exists
        model = name.safe_constantize
        report = SchemaSuggestions.new(model).call
        requested = requested_fields
        enabled = requested.empty? ? report.suggestions.dup : enabled_suggestions(name, report, requested)
        Plan.new(model_name: name, model: report.available ? model : nil, constant: constant, key: key, target: target,
          available: report.available, enabled: enabled, rest: report.suggestions - enabled, omitted: report.omitted, panels: [])
      end

      def self.resource_key(name) = name.underscore.tr("/", "_").pluralize

      # Model name => registered resource key, for references and panels.
      def resource_keys(plans)
        keys = RailsAiAdmin.registry.resources.each_with_object({}) { |resource, map| map[resource.model] ||= resource.key.to_s }
        plans.each { |plan| keys[plan.model_name] = plan.key if plan.available }
        keys
      end

      # A reference needs its target registered. Without one it stays a
      # comment, unless --fields asked for it by name.
      def resolve_references(plan, keys)
        plan.enabled = plan.enabled.filter_map do |suggestion|
          next suggestion unless suggestion.type == :belongs_to
          target = association_model(plan.model, suggestion.name)
          key = target && keys[target]
          if key
            key == suggestion.name.pluralize ? suggestion : suggestion.with(options: { resource: key.to_sym, **suggestion.options }.freeze)
          elsif options[:fields].any?
            suggestion
          else
            plan.rest << suggestion
            nil
          end
        end
        plan.enabled.concat(attachment_fields(plan)) if options[:fields].empty?
        plan.hints = password_hints(plan)
      end

      # has_secure_password attributes, offered as a commented write-only
      # field: setting someone's password is a decision to make on purpose.
      def password_hints(plan)
        model = plan.model
        return [] unless model
        model.column_names.filter_map do |column|
          name = column.delete_suffix("_digest")
          next unless column.end_with?("_digest") && name.match?(NAME) && model.method_defined?("#{name}=") && model.method_defined?("authenticate_#{name}")
          name
        end
      end

      def association_model(model, name)
        model&.reflect_on_association(name.to_sym)&.klass&.name
      rescue NameError, ArgumentError
        nil
      end

      # has_one_attached, has_many_attached and has_rich_text declarations.
      def attachment_fields(plan)
        model = plan.model
        return [] unless model
        taken = plan.enabled.map(&:name) + plan.rest.map(&:name)
        attachments = model.respond_to?(:reflect_on_all_attachments) ? model.reflect_on_all_attachments : []
        fields = attachments.map { |attachment| [ attachment.name.to_s, attachment.macro == :has_many_attached ? :files : :file ] }
        rich = model.respond_to?(:rich_text_association_names) ? model.rich_text_association_names : []
        fields += rich.map { |association| [ association.to_s.delete_prefix("rich_text_"), :rich_text ] }
        fields.filter_map do |name, type|
          next if !name.match?(NAME) || taken.include?(name) || SchemaSuggestions.sensitive?(model, name)
          SchemaSuggestions::Suggestion.new(name, type, {}.freeze)
        end
      end

      # Picks the title and the list flags: search by the title and emails,
      # sort by numbers and dates, filter by flags, enums and references.
      def enrich(plan)
        title = plan.enabled.find { |suggestion| suggestion.type == :text } || plan.enabled.find { |suggestion| suggestion.type == :email }
        plan.title = title&.name || "id"
        plan.enabled = plan.enabled.map do |suggestion|
          extra = {}
          extra[:create] = false if suggestion.options[:readonly]
          if suggestion.name == plan.title
            extra.merge!(searchable: :contains, sortable: true)
          elsif suggestion.type == :email
            extra[:searchable] = true
          end
          extra[:sortable] = true if SORTABLE.include?(suggestion.type)
          extra[:filterable] = true if FILTERABLE.include?(suggestion.type)
          suggestion.with(options: suggestion.options.merge(extra).freeze)
        end
      end

      # Readonly child panels for has_many and has_one associations whose
      # child resource declares the reference back to this model.
      def panels(plan, keys)
        return [] unless plan.model
        candidates = plan.model.reflect_on_all_associations.select do |association|
          %i[has_many has_one].include?(association.macro) && !association.options[:through] && !association.options[:as] && association.name.to_s.match?(NAME)
        end
        candidates.filter_map do |association|
          child = association.klass
          key = keys[child.name]
          back = key && child.reflect_on_all_associations(:belongs_to).find do |reference|
            !reference.polymorphic? && reference.foreign_key.to_s == association.foreign_key.to_s && reference.klass.name == plan.model_name
          end
          next unless back && reference_declared?(child.name, back.name.to_s)
          single = association.macro == :has_one
          arguments = [ ":#{association.name}" ]
          arguments << "resource: :#{key}" unless key == (single ? association.name.to_s.pluralize : association.name.to_s)
          arguments << "via: :#{back.name}" unless back.name.to_s == plan.model_name.demodulize.underscore
          "#{association.macro} #{arguments.join(', ')}"
        rescue NameError, ArgumentError
          nil
        end.first(Presentation::AssociationPanel::MAX_PANELS)
      end

      def reference_declared?(model_name, field)
        if (plan = @plans.find { |candidate| candidate.model_name == model_name })
          return plan.enabled.any? { |suggestion| suggestion.type == :belongs_to && suggestion.name == field }
        end
        resource = RailsAiAdmin.registry.resources.find { |candidate| candidate.model == model_name }
        resource ? resource.fields.any? { |candidate| candidate.scalar_type == :belongs_to && candidate.name.to_s == field } : false
      end

      def source(plan)
        notes = if plan.available
          [ *(plan.rest.any? ? [ "# Not enabled. Review sensitivity and policy before uncommenting:" ] : []),
            *plan.rest.map { |suggestion| "# #{suggestion.declaration}" },
            *(plan.omitted.positive? ? [ "# #{plan.omitted} sensitive, relationship, internal or unsupported columns omitted." ] : []),
            *Array(plan.hints).flat_map do |name|
              [ "# Write-only: lets admins set this #{name.humanize.downcase}. Records that require one",
                "# cannot be created here without it.", "# password :#{name}" ]
            end ]
        else
          [ "# Schema unavailable. Migrate the model and rerun, or add reviewed scalar fields manually." ]
        end
        body = [ "id :id", *plan.enabled.map(&:declaration), *notes ].map { |line| "    #{line}" }
        lines = [ "class #{plan.constant} < RailsAiAdmin::Resource", "  model \"#{plan.model_name}\"", "  key :#{plan.key}", "  title :#{plan.title || 'id'}" ]
        if plan.available && !plan.versioned? && !options[:readonly]
          lines << "  # #{plan.model_name} has no updated_at or lock_version column, which saving needs to"
          lines << "  # notice an edit made in between. Add timestamps, then remove this line."
        end
        lines << "  readonly" if readonly?(plan)
        lines.push("  fields do", *body, "  end")
        lines.concat(index_lines(plan))
        lines.concat(plan.panels.map { |panel| "  #{panel}" })
        lines << "end"
        "#{lines.join("\n")}\n"
      end

      def readonly?(plan) = options[:readonly] || !plan.available || !plan.versioned?

      # The list shows the title and the short fields, newest first when
      # there is a creation time, with a bounded exact count. Long text and
      # the update time stay on the record's page.
      def index_lines(plan)
        return [] unless plan.available
        lines = [ "  index do" ]
        listed = plan.enabled.reject { |suggestion| UNLISTED.include?(suggestion.type) || suggestion.name == "updated_at" }
        created, rest = listed.partition { |suggestion| suggestion.name == "created_at" }
        title, others = rest.partition { |suggestion| suggestion.name == plan.title }
        picks = (title + others).first(LISTED - 1 - created.size) + created
        lines << "    columns #{[ ':id', *picks.map { |suggestion| ":#{suggestion.name}" } ].join(', ')}"
        lines << "    default_sort :created_at, :desc" if created.any? { |suggestion| suggestion.options[:sortable] }
        lines.push("    count :exact", "  end")
      end

      # Rewrites the config.resources list in the initializer, keeping its
      # current entries. Returns false when there is no single list to edit.
      def register(constants)
        path = File.join(destination_root, INITIALIZER)
        return false unless File.exist?(path)
        content = File.read(path)
        matches = content.scan(RESOURCES)
        return false unless matches.size == 1
        match = content.match(RESOURCES)
        list = match[:list]
        quoted = /"[^"]*"|'[^']*'/
        # Only plain lists of quoted or %w names are rewritten.
        return false unless list.start_with?("%w") || list[1..-2].gsub(quoted, "").match?(/\A[\s,]*\z/)
        current = list.start_with?("%w") ? list[3..-2].split : list.scan(quoted).map { |name| name[1..-2] }
        return false unless current.all? { |name| name.match?(/\A[A-Z]\w*(?:::[A-Z]\w*)*\z/) }
        names = current | constants
        return true if names == current
        indent = match[:indent]
        list = names.size <= 3 ? "%w[#{names.join(' ')}]" : "%w[\n#{names.map { |name| "#{indent}  #{name}\n" }.join}#{indent}]"
        gsub_file INITIALIZER, RESOURCES, "#{indent}config.resources = #{list}"
        true
      end

      def full_access?
        adapter = RailsAiAdmin.configuration.authorization_adapter.to_s.safe_constantize
        adapter.is_a?(Class) && adapter <= Authorization::FullAccessAdapter
      end

      # name or name:type tokens, in order, without duplicates.
      def requested_fields
        options[:fields].each_with_object({}) do |token, fields|
          match = token.to_s.match(FIELD)
          raise Rails::Generators::Error, "Use name or name:type for --fields, not #{token.inspect}" unless match
          raise Rails::Generators::Error, "#{match[1]} is listed twice in --fields" if fields.key?(match[1])
          fields[match[1]] = match[2]
        end
      end

      # Only fields the schema already suggests can be enabled, so the same
      # sensitivity, relationship and tenant rules apply to --fields.
      def enabled_suggestions(name, report, requested)
        raise Rails::Generators::Error, "Schema unavailable for #{name}; migrate the model before using --fields" unless report.available
        by_name = report.suggestions.index_by(&:name)
        requested.map do |field, type|
          suggestion = by_name[field]
          unless suggestion
            raise Rails::Generators::Error, "#{field} is not a suggested field of #{name} (sensitive, relationship, internal, unsupported or missing). Add it by hand after review."
          end
          if type && type != suggestion.type.to_s
            raise Rails::Generators::Error, "#{field} is #{suggestion.type} in the schema, not #{type}"
          end
          suggestion
        end
      end
    end
  end
end
