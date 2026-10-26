# frozen_string_literal: true

require "rails_helper"

RSpec.describe IsbfCalendar::Entry, "reminders" do
  fab!(:user) { Fabricate(:user, approved: true) }

  before { freeze_time Time.utc(2026, 1, 1) }

  def entry(**attributes)
    Fabricate(:isbf_calendar_entry, user:, **attributes)
  end

  it "keeps every timed offset anchored to the stored instant" do
    IsbfCalendar::Reminders::TIMED_OFFSETS.each do |mode, offset|
      record = entry(reminder_mode: mode, starts_at: Time.iso8601("2026-10-20T09:00:00+08:00"))
      expect(record.reminder_at).to eq(Time.utc(2026, 10, 20, 1) - offset)
    end
  end

  it "uses the manual UTC date and local 9am across DST instead of subtracting 24 hours" do
    record = entry(
      all_day: true,
      starts_at: Time.utc(2026, 3, 8),
      ends_at: Time.utc(2026, 3, 9),
      reminder_mode: "same_day_9am",
      reminder_timezone: "America/New_York",
    )
    expect(record.reminder_at).to eq(Time.utc(2026, 3, 8, 13))
    record.update!(reminder_mode: "previous_day_9am")
    expect(record.reminder_at).to eq(Time.utc(2026, 3, 7, 14))
  end

  it "uses Shanghai dates and a fixed Shanghai zone for official all-day snapshots" do
    source = Fabricate(
      :isbf_calendar_official_item,
      all_day: true,
      starts_at: Time.iso8601("2026-10-20T00:00:00+08:00"),
      ends_at: Time.iso8601("2026-10-21T00:00:00+08:00"),
    )
    record = Fabricate(
      :isbf_calendar_official_entry,
      user:,
      source_item: source,
      reminder_mode: "same_day_9am",
      reminder_timezone: "America/New_York",
    )
    expect(record.reminder_timezone).to eq("Asia/Shanghai")
    expect(record.reminder_at).to eq(Time.utc(2026, 10, 20, 1))
  end

  it "requires an IANA timezone for personal all-day reminders and rejects mismatched modes" do
    record = Fabricate.build(
      :isbf_calendar_entry,
      user:,
      all_day: true,
      reminder_mode: "same_day_9am",
    )
    expect(record).not_to be_valid
    record.reminder_timezone = "UTC+8"
    expect(record).not_to be_valid
    record.reminder_timezone = "Asia/Shanghai"
    expect(record).to be_valid
    record.reminder_mode = "before_5m"
    expect(record).not_to be_valid
    record.all_day = false
    record.reminder_mode = "same_day_9am"
    expect(record).not_to be_valid
  end

  it "preserves processed and exported state on note, title, location, and end-only edits" do
    record = entry(reminder_mode: "before_15m")
    record.update_columns(
      reminder_processed_at: Time.current,
      reminder_delivery: "in_app",
      reminder_exported_generation: record.reminder_generation,
      reminder_exported_key_id: 123,
      reminder_exported_policy: "policy",
    )
    previous = record.attributes.slice(*record.attributes.keys.grep(/^reminder_/))
    record.update!(note: "Bring notes", title: "New title", location: "Library", ends_at: record.ends_at + 1.hour)
    expect(record.attributes.slice(*previous.keys)).to eq(previous)
  end

  it "invalidates export evidence and the processed marker when its schedule changes" do
    record = entry(reminder_mode: "before_15m")
    generation = record.reminder_generation
    record.update_columns(reminder_processed_at: Time.current, reminder_exported_generation: generation)
    record.update!(starts_at: record.starts_at + 1.hour, ends_at: record.ends_at + 1.hour)
    expect(record.reminder_generation).to eq(generation + 1)
    expect(record.reminder_processed_at).to be_nil
    expect(record.reminder_exported_generation).to be_nil
  end

  it "clears reminders explicitly and resets incompatible modes when all-day changes" do
    record = entry(reminder_mode: "before_15m")
    record.update!(all_day: true)
    expect(record.reminder_mode).to eq("none")
    expect(record.reminder_at).to be_nil
    record.update!(reminder_mode: "same_day_9am", reminder_timezone: "Asia/Shanghai")
    record.update!(reminder_mode: "none")
    expect(record.reminder_at).to be_nil
    expect(record.reminder_timezone).to be_nil
  end

  it "accepts a newly configured past reminder without making it eligible for catch-up" do
    freeze_time Time.utc(2026, 10, 20, 0, 55)
    record = entry(reminder_mode: "before_15m")
    expect(record.reminder_at).to eq(Time.utc(2026, 10, 20, 0, 45))
    expect(record.reminder_processed_at).to eq(Time.current)
    expect(record.reminder_delivery).to be_nil
  end
end
