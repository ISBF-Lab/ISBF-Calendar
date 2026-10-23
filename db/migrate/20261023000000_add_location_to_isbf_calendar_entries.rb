# frozen_string_literal: true

class AddLocationToIsbfCalendarEntries < ActiveRecord::Migration[7.2]
  def change
    add_column :isbf_calendar_entries, :location, :string, limit: 255
  end
end
