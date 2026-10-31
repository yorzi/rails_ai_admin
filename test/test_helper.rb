# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require "bundler/setup"
require "minitest/autorun"
require "rails_ai_admin"
require "webmock/minitest"
WebMock.disable_net_connect!

class TestActor
  attr_reader :id
  def initialize(id) = @id = id
end

class TestTenant
  attr_reader :id
  def initialize(id) = @id = id
end

class TestResource < RailsAiAdmin::Resource
  model "Customer"
  key :customers
  title :name
  fields do
    id :id
    text :name, required: true, nullable: false, searchable: :prefix, sortable: true
    text :secret, readonly: true
    integer :points
    boolean :active
  end
  scopes do
    scope :active, -> { where(active: true) }, label: "Active", default: true
    scope :rewarded, -> { where(points: 1..) }
    scope :all, label: "All customers"
  end
end

module ContextHelpers
  def context(actor: 1, tenant: 1, version: "1")
    RailsAiAdmin::Context.new(actor: TestActor.new(actor), tenant: TestTenant.new(tenant), security_version: version)
  end
end

class Minitest::Test
  include ContextHelpers
end
