# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_20_000006) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "categories", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.integer "position", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_categories_on_name", unique: true
    t.index ["position"], name: "index_categories_on_position"
  end

  create_table "items", force: :cascade do |t|
    t.datetime "archived_at"
    t.bigint "category_id"
    t.datetime "created_at", null: false
    t.integer "current_quantity", default: 0, null: false
    t.integer "default_pack_size"
    t.integer "estimation_mode", default: 0, null: false
    t.integer "expiry_warning_days"
    t.boolean "favorite", default: false, null: false
    t.date "last_consumed_on"
    t.integer "manual_interval_days"
    t.integer "minimum_quantity"
    t.string "name", null: false
    t.string "name_reading"
    t.text "note"
    t.integer "soon_threshold_days"
    t.bigint "storage_location_id"
    t.date "tracking_started_on"
    t.boolean "tracks_expiry", default: false, null: false
    t.boolean "tracks_purposes", default: false, null: false
    t.string "unit", default: "個", null: false
    t.datetime "updated_at", null: false
    t.integer "urgent_threshold_days"
    t.index ["archived_at"], name: "index_items_on_archived_at"
    t.index ["category_id"], name: "index_items_on_category_id"
    t.index ["favorite"], name: "index_items_on_favorite"
    t.index ["name"], name: "index_items_on_name"
    t.index ["storage_location_id"], name: "index_items_on_storage_location_id"
    t.check_constraint "current_quantity >= 0", name: "items_current_quantity_non_negative"
  end

  create_table "lots", force: :cascade do |t|
    t.date "acquired_on", null: false
    t.datetime "created_at", null: false
    t.datetime "depleted_at"
    t.date "expires_on"
    t.integer "initial_quantity", null: false
    t.bigint "item_id", null: false
    t.integer "kind", default: 0, null: false
    t.text "note"
    t.integer "pack_count"
    t.integer "pack_size"
    t.integer "price_yen"
    t.integer "remaining_quantity", default: 0, null: false
    t.bigint "store_id"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["expires_on"], name: "index_lots_on_expires_on"
    t.index ["id", "item_id"], name: "index_lots_on_id_and_item_id", unique: true
    t.index ["item_id", "depleted_at"], name: "index_lots_on_item_id_and_depleted_at"
    t.index ["item_id", "expires_on"], name: "index_lots_on_item_id_and_expires_on"
    t.index ["store_id"], name: "index_lots_on_store_id"
    t.index ["user_id"], name: "index_lots_on_user_id"
    t.check_constraint "(pack_size IS NULL) = (pack_count IS NULL)", name: "lots_pack_pair"
    t.check_constraint "initial_quantity > 0", name: "lots_initial_quantity_positive"
    t.check_constraint "pack_size IS NULL OR (pack_size * pack_count) = initial_quantity", name: "lots_pack_quantity_matches"
    t.check_constraint "remaining_quantity >= 0", name: "lots_remaining_quantity_non_negative"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "solid_cache_entries", force: :cascade do |t|
    t.integer "byte_size", null: false
    t.datetime "created_at", null: false
    t.binary "key", null: false
    t.bigint "key_hash", null: false
    t.binary "value", null: false
    t.index ["byte_size"], name: "index_solid_cache_entries_on_byte_size"
    t.index ["key_hash", "byte_size"], name: "index_solid_cache_entries_on_key_hash_and_byte_size"
    t.index ["key_hash"], name: "index_solid_cache_entries_on_key_hash", unique: true
  end

  create_table "solid_queue_batch_executions", force: :cascade do |t|
    t.bigint "batch_id", null: false
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.index ["batch_id"], name: "index_solid_queue_batch_executions_on_batch_id"
    t.index ["job_id"], name: "index_solid_queue_batch_executions_on_job_id", unique: true
  end

  create_table "solid_queue_batches", force: :cascade do |t|
    t.string "active_job_batch_id"
    t.integer "completed_jobs", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "description"
    t.datetime "enqueued_at"
    t.datetime "failed_at"
    t.integer "failed_jobs", default: 0, null: false
    t.datetime "finished_at"
    t.text "metadata"
    t.text "on_failure"
    t.text "on_finish"
    t.text "on_success"
    t.integer "total_jobs", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["active_job_batch_id"], name: "index_solid_queue_batches_on_active_job_batch_id", unique: true
    t.index ["finished_at"], name: "index_solid_queue_batches_on_finished_at"
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.string "concurrency_key", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error"
    t.bigint "job_id", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "active_job_id"
    t.text "arguments"
    t.bigint "batch_id"
    t.string "class_name", null: false
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at"
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["batch_id"], name: "index_solid_queue_jobs_on_batch_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "queue_name", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "hostname"
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.text "metadata"
    t.string "name", null: false
    t.integer "pid", null: false
    t.bigint "supervisor_id"
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.datetime "run_at", null: false
    t.string "task_key", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.text "arguments"
    t.string "class_name"
    t.string "command", limit: 2048
    t.datetime "created_at", null: false
    t.text "description"
    t.string "key", null: false
    t.integer "priority", default: 0
    t.string "queue_name"
    t.string "schedule", null: false
    t.boolean "static", default: true, null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.integer "value", default: 1, null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "stock_movements", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "disposal_reason"
    t.bigint "item_id", null: false
    t.integer "kind", null: false
    t.bigint "lot_id", null: false
    t.text "note"
    t.date "occurred_on", null: false
    t.integer "quantity", null: false
    t.bigint "stock_take_entry_id"
    t.datetime "updated_at", null: false
    t.bigint "usage_record_id"
    t.bigint "user_id", null: false
    t.index ["item_id", "occurred_on"], name: "index_stock_movements_on_item_id_and_occurred_on"
    t.index ["kind", "occurred_on"], name: "index_stock_movements_on_kind_and_occurred_on"
    t.index ["lot_id"], name: "index_stock_movements_on_lot_id"
    t.index ["stock_take_entry_id"], name: "index_stock_movements_on_stock_take_entry_id"
    t.index ["usage_record_id"], name: "index_stock_movements_on_usage_record_id"
    t.index ["user_id"], name: "index_stock_movements_on_user_id"
    t.check_constraint "disposal_reason IS NULL OR kind = 3", name: "stock_movements_disposal_reason_only_for_disposal"
    t.check_constraint "kind = 0 AND quantity > 0 OR (kind = ANY (ARRAY[1, 3])) AND quantity < 0 OR kind = 2", name: "stock_movements_quantity_sign_matches_kind"
    t.check_constraint "quantity <> 0", name: "stock_movements_quantity_not_zero"
  end

  create_table "storage_locations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.integer "position", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_storage_locations_on_name", unique: true
    t.index ["position"], name: "index_storage_locations_on_position"
  end

  create_table "stores", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.text "note"
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_stores_on_name", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "deactivated_at"
    t.string "email_address", null: false
    t.string "name", null: false
    t.boolean "notify_expiries", default: true, null: false
    t.boolean "notify_purchases", default: true, null: false
    t.string "password_digest", null: false
    t.integer "role", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  add_foreign_key "items", "categories", on_delete: :nullify
  add_foreign_key "items", "storage_locations", on_delete: :nullify
  add_foreign_key "lots", "items"
  add_foreign_key "lots", "stores", on_delete: :nullify
  add_foreign_key "lots", "users", on_delete: :restrict
  add_foreign_key "sessions", "users"
  add_foreign_key "solid_queue_batch_executions", "solid_queue_batches", column: "batch_id", on_delete: :cascade
  add_foreign_key "solid_queue_batch_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "stock_movements", "items"
  add_foreign_key "stock_movements", "lots", column: ["lot_id", "item_id"], primary_key: ["id", "item_id"]
  add_foreign_key "stock_movements", "users", on_delete: :restrict
end
