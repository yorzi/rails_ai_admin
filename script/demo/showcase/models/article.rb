class Article < ApplicationRecord
  belongs_to :account
  has_secure_password :password, validations: false
  has_one_attached :cover
  has_many_attached :gallery
  has_rich_text :body
  has_many :taggings, dependent: :delete_all
  has_many :tags, through: :taggings
  has_one :summary, dependent: :delete
  validates :title, presence: true
  validates :password, length: { minimum: 8 }, allow_nil: true
end
