class CreateStorageLocations < ActiveRecord::Migration[8.1]
  def change
    create_table :storage_locations do |t|
      t.string :name, null: false
      t.integer :position, null: false, default: 0

      t.timestamps
    end
    add_index :storage_locations, :name, unique: true
    add_index :storage_locations, :position
  end
end
