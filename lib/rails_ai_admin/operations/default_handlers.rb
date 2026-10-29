# frozen_string_literal: true

module RailsAiAdmin
  module Operations
    module DefaultHandlers # :nodoc:
      class Create
        def perform(_context, record, _input) = record.save!
      end
      class Update < Create
      end
      class Destroy
        def perform(_context, record, _input) = record.destroy!
      end
      TYPES = { "create" => Create, "update" => Update, "destroy" => Destroy }.freeze
    end
  end
end
