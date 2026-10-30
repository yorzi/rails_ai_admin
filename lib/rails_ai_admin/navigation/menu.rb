# frozen_string_literal: true

module RailsAiAdmin
  module Navigation
    # Fresh authorized scalar snapshots; no record/count query or stored grants.
    class Menu
      Entry = Data.define(:key, :label, :icon, :current)
      Group = Data.define(:label, :entries)

      def self.build(context:, resources:, current_key: nil)
        raise AccessDenied, "UNAUTHENTICATED" unless context.is_a?(Context)
        entries = resources.each_with_index.filter_map do |resource, index|
          begin
            Authorization::Access.new(context, resource).authorize!(:index)
          rescue AccessDenied
            next
          end
          settings = resource.navigation
          next if settings.hidden
          label = Settings.caption(settings.label || resource.label)
          raise ConfigurationError, "Navigation requires a label" unless label
          entry = Entry.new(String.new(resource.key.to_s).freeze, label, settings.icon, current_key == resource.key)
          [ settings, index, entry ]
        end
        entries.sort_by { |settings, index, _| [ settings.order, index ] }
          .group_by { |settings, _, _| settings.group }
          .map { |label, rows| Group.new(label, rows.map(&:last).freeze) }.freeze
      end
    end
  end
end
