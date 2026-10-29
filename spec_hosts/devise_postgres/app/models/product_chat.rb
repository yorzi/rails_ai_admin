class ProductChat < ApplicationRecord
  acts_as_chat messages: :product_messages, message_class: "ProductMessage", messages_foreign_key: :product_chat_id
end
