class CreateStores < ActiveRecord::Migration[8.1]
  def change
    create_table :stores, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :name, null: false
      t.text :note

      t.timestamps
    end
    add_index :stores, :name, unique: true
  end
end
