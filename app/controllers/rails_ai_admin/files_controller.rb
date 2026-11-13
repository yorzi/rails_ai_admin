# frozen_string_literal: true

module RailsAiAdmin
  # Serves an attached file after the same checks as the record's page: the
  # record in scope, its show grant and a current read grant for the field.
  # Only raster images are shown inline; everything else downloads.
  class FilesController < ApplicationController
    def show
      raise AccessDenied unless defined?(::ActiveStorage::Blob)
      resource = RailsAiAdmin.registry.fetch(params[:resource])
      access = Authorization::Access.new(@context, resource)
      raise AccessDenied unless access.canonical_id?(params[:id])
      record = access.find!(params[:id])
      field = access.fields(:read, record).find { |candidate| candidate.scalar_type == :file && candidate.name.to_s == params[:field] }
      raise AccessDenied unless field
      attached = access.attachment(record, field)
      raise AccessDenied unless attached.attached?
      blob = attached.blob
      inline = params[:disposition] == "inline" && Fields::INLINE_IMAGE_TYPES.include?(blob.content_type)
      # A served file is a document of its own: no script, no framing.
      response.headers["Content-Security-Policy"] = "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; sandbox"
      response.headers["Cache-Control"] = "no-store, private"
      response.headers["Content-Type"] = inline ? blob.content_type : "application/octet-stream"
      response.headers["Content-Disposition"] = ActionDispatch::Http::ContentDisposition.format(
        disposition: inline ? "inline" : "attachment", filename: blob.filename.sanitized)
      response.headers["Content-Length"] = blob.byte_size.to_s
      # Streamed in the service's chunks; a large file is never held in memory.
      self.response_body = Enumerator.new { |body| blob.download { |chunk| body << chunk } }
    end
  end
end
