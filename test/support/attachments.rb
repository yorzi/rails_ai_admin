# frozen_string_literal: true

require "support/application"
require "support/essentials"

# File fields on a model with Active Storage attachments and no lock_version.
class Document < ActiveRecord::Base
  has_one_attached :cover
  has_one_attached :contract
  has_rich_text :body
  validates :title, presence: true
end

module AttachmentFixtures
  class DocumentAdmin < RailsAiAdmin::Resource
    model "Document"
    key :documents
    title :title
    fields do
      id :id
      text :title, required: true, nullable: false
      file :cover, accept: %w[image/*], max_size: 1024 * 1024
      file :contract, accept: %w[application/pdf]
      rich_text :body, index: true
    end
  end

  class Policy < RailsAiAdmin::Authorization::Adapter
    class_attribute :read, default: %i[id title cover contract body]
    class_attribute :write, default: %i[title cover contract body]

    def self.reset!
      self.read = %i[id title cover contract body]
      self.write = %i[title cover contract body]
    end

    def scope(context:, resource:, relation:) = relation.where(account_id: context.tenant.id)
    def allowed?(context:, action:, resource:, record: nil) = context.actor.id == 1 || %i[index show].include?(action)

    def fields(context:, resource:, action:, record: nil)
      case action
      when :read then read
      when :write then context.actor.id == 1 ? write : []
      else []
      end
    end

    def view_history?(context:, resource:, record:) = true
  end

  PNG = [ "89504e470d0a1a0a0000000d4948445200000001000000010806000000" \
    "1f15c4890000000d49444154789c6360000002000154a24f5d0000000049454e44ae426082" ].pack("H*").freeze
  PDF = "%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n"
  SVG = %(<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>)

  def self.prepare_schema
    return if Document.table_exists?
    ActiveRecord::Schema.define do
      create_table :documents do |t|
        t.integer :account_id, null: false
        t.string :title, null: false
        t.timestamps
      end
    end
  end

  def with_document_resources(&block)
    config = RailsAiAdmin.configuration.dup
    config.authorization_adapter = "AttachmentFixtures::Policy"
    registry = RailsAiAdmin::Registry.new(%w[AttachmentFixtures::DocumentAdmin])
    operations = RailsAiAdmin::Operations::Registry.new(registry.resources)
    RailsAiAdmin.stub(:configuration, config) do
      RailsAiAdmin.stub(:registry, registry) do
        RailsAiAdmin.stub(:operation_registry, operations) { yield registry }
      end
    end
  end

  def upload(content, filename, type)
    Rack::Test::UploadedFile.new(StringIO.new(content), type, original_filename: filename)
  end

  def reset_documents
    Policy.reset!
    ActionText::RichText.delete_all
    ActiveStorage::Attachment.delete_all
    ActiveStorage::Blob.delete_all
    Document.delete_all
    @document = Document.create!(account_id: 1, title: "Handbook")
  end
end

AttachmentFixtures.prepare_schema
