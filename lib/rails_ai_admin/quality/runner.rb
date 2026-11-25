# frozen_string_literal: true

module RailsAiAdmin
  module Quality
    Finding = Data.define(:finding_key, :record_ids, :summary, :evidence_fields)

    class Runner
      MAX_RECORDS = 20
      MAX_FIELDS = 10
      EVIDENCE_TYPES = %i[id text textarea email url integer decimal boolean date datetime time enum select belongs_to].freeze
      Row = Data.define(:id, :evidence, :can_remediate)
      Review = Data.define(:key, :summary, :rows)
      Report = Data.define(:rule, :reviews)

      def initialize(access, assistant: false)
        @access = access
        @assistant = assistant
      end

      def call(key)
        rule = RailsAiAdmin.quality_registry.fetch(@access.resource, key)
        raise AccessDenied unless @access.quality_rule_allowed?(rule)
        deadline = monotonic + rule.max_duration
        reviews = []
        ActiveRecord::Base.while_preventing_writes do
          relation = Queries::List.unique_records(@access.relation)
          candidates = rule.new.run_detection(@access, relation, assistant: @assistant)
          raise ConfigurationError, "Quality rule must return findings" unless candidates.is_a?(Enumerable)
          candidates.lazy.take(rule.max_findings).each do |finding|
            check_deadline!(deadline)
            review = project(rule, finding, relation)
            reviews << review if review
          end
          check_deadline!(deadline)
          Report.new(rule, reviews)
        end
      rescue ActiveRecord::ReadOnlyError
        raise ConfigurationError, "Quality detectors must be read-only", cause: nil
      rescue AccessDenied, ConfigurationError
        raise
      rescue StandardError
        raise ConfigurationError, "Quality rule could not run", cause: nil
      end

      private

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def check_deadline!(deadline)
        raise ConfigurationError, "Quality rule exceeded its cooperative deadline" if monotonic >= deadline
      end

      def project(rule, finding, relation)
        unless finding.is_a?(Finding) && finding.finding_key.is_a?(String) && finding.finding_key.bytesize.between?(1, 150) &&
            finding.record_ids.is_a?(Array) && finding.record_ids.size.between?(1, MAX_RECORDS) &&
            finding.record_ids.all? { |id| @access.canonical_id?(id) } && finding.evidence_fields.is_a?(Array) &&
            finding.evidence_fields.size <= MAX_FIELDS && finding.evidence_fields.all? { |name| name.is_a?(Symbol) } &&
            finding.summary.is_a?(String) && finding.summary.valid_encoding? && finding.summary.length.between?(1, 300) && !finding.summary.match?(Field::TEXT_CONTROLS)
          raise ConfigurationError, "Invalid quality finding"
        end
        ids = finding.record_ids.map(&:to_s).uniq
        records = relation.where(relation.klass.primary_key => ids).index_by { |record| record.id.to_s }
        return unless records.size == ids.size
        rows = ids.map do |id|
          record = records.fetch(id)
          fields = @access.resource.fields.select { |field| finding.evidence_fields.include?(field.name) && EVIDENCE_TYPES.include?(field.scalar_type) }
          # Membership itself reveals the predicate. Withhold the whole group
          # if even one candidate or required evidence field cannot be shown.
          values = @access.project(record, view: :show, only: fields.map(&:name))
          return unless finding.evidence_fields.all? { |name| values.key?(name.to_s) }
          evidence = fields.to_h do |field|
            name = field.name.to_s
            [ name, field.format(values.fetch(name), time_zone: @access.context.time_zone).truncate(300) ]
          end
          Row.new(id, evidence, can_remediate?(rule, record))
        end
        Review.new(InputSchema.digest([ finding.finding_key, ids.sort ]), finding.summary, rows)
      rescue AccessDenied
        nil
      end

      def can_remediate?(rule, record)
        action = rule.remediation_operation || rule.remediation_change
        action && @access.authorize!(action, record)
      rescue AccessDenied
        false
      end
    end
  end
end
