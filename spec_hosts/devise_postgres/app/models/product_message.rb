class ProductMessage < ApplicationRecord
  acts_as_message chat: :product_chat, chat_class: "ProductChat", chat_foreign_key: :product_chat_id
end
