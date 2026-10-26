# frozen_string_literal: true

class AddRemindersToIsbfCalendarEntries < ActiveRecord::Migration[7.2]
  def change
    add_column :isbf_calendar_entries, :reminder_mode, :string, null: false, default: "none"
    add_column :isbf_calendar_entries, :reminder_timezone, :string
    add_column :isbf_calendar_entries, :reminder_at, :datetime
    add_column :isbf_calendar_entries, :reminder_configured_at, :datetime
    add_column :isbf_calendar_entries, :reminder_generation, :bigint, null: false, default: 0
    add_column :isbf_calendar_entries, :reminder_processed_at, :datetime
    add_column :isbf_calendar_entries, :reminder_delivery, :string
    add_column :isbf_calendar_entries, :reminder_exported_generation, :bigint
    add_column :isbf_calendar_entries, :reminder_exported_key_id, :bigint
    add_column :isbf_calendar_entries, :reminder_exported_policy, :string
    add_index :isbf_calendar_entries, :reminder_at,
              where: "reminder_at IS NOT NULL AND reminder_processed_at IS NULL",
              name: "idx_isbf_calendar_pending_reminders"
  end
end
