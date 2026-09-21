class CreateCategories < ActiveRecord::Migration[8.1]
  def change
    create_table :categories, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :name, null: false
      t.integer :position, null: false, default: 0

      t.timestamps
    end
    add_index :categories, :name, unique: true
    add_index :categories, :position
  end
end
