# frozen_string_literal: true

ActiveRecord::Schema.define(version: 1) do
  create_table :posts, force: :cascade do |t|
    t.string :title
  end
end
