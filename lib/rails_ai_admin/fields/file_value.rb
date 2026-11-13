# frozen_string_literal: true

module RailsAiAdmin
  module Fields
    # Raster images a browser may show inline. SVG and HTML never are: they
    # can carry script.
    INLINE_IMAGE_TYPES = %w[image/png image/jpeg image/gif image/webp image/avif].freeze

    # A chosen file the page refused before uploading it (too large).
    RejectedUpload = Data.define(:reason, :limit)

    # The readable facts about one attached file. Pages link to it through the
    # admin's own download route, never through a public blob URL.
    FileValue = Data.define(:filename, :content_type, :byte_size, :checksum) do
      def self.from(blob)
        new(blob.filename.to_s.freeze, blob.content_type.to_s.freeze, blob.byte_size, blob.checksum.to_s.freeze)
      end

      def image? = INLINE_IMAGE_TYPES.include?(content_type)
    end
  end
end
