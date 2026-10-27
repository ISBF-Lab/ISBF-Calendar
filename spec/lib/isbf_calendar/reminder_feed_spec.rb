# frozen_string_literal: true

require "rails_helper"

RSpec.describe IsbfCalendar::SubscriptionFeed, "reminder alarms" do
  fab!(:user) { Fabricate(:user, approved: true) }
  fab!(:category)
  fab!(:topic) { Fabricate(:topic_with_op, category:) }
  fab!(:source) { Fabricate(:isbf_calendar_official_item, topic:) }

  before do
    freeze_time Time.utc(2026, 10, 19)
    SiteSetting.isbf_calendar_reminder_delivery_mode = "subscription_preferred"
    allow(IsbfCalendar).to receive(:official_category_id).and_return(category.id)
  end

  def feed(*entries)
    described_class.new(entries:, guardian: user.guardian)
  end

  it "exports one escaped DISPLAY alarm per valid future reminder without writing export evidence" do
    record = Fabricate(
      :isbf_calendar_entry,
      user:,
      title: "Library; study, day\nTwo",
      reminder_mode: "before_5m",
    )
    calendar = feed(record)
    body = calendar.to_ical
    expect(body.scan("BEGIN:VALARM").length).to eq(1)
    expect(body).to include(
      "ACTION:DISPLAY\r\n",
      "TRIGGER:-PT5M\r\n",
      'DESCRIPTION:Library\; study\, day\nTwo',
    )
    expect(calendar.reminder_exports).to eq([
      { id: record.id, generation: record.reminder_generation, at: record.reminder_at },
    ])
    expect(record.reload.reminder_exported_generation).to be_nil
    expect(calendar.to_ical.scan("BEGIN:VALARM").length).to eq(1)
    expect(calendar.reminder_exports.length).to eq(1)
  end

  {
    "before_5m" => ["-PT5M", 5.minutes],
    "before_15m" => ["-PT15M", 15.minutes],
    "before_30m" => ["-PT30M", 30.minutes],
    "before_1h" => ["-PT1H", 1.hour],
    "before_24h" => ["-PT24H", 24.hours],
  }.each do |mode, (trigger, offset)|
    it "exports #{mode} relative to the event start with the saved UTC target" do
      record = Fabricate(
        :isbf_calendar_entry,
        user:,
        starts_at: Time.utc(2026, 10, 22, 1),
        ends_at: Time.utc(2026, 10, 22, 2),
        reminder_mode: mode,
      )
      calendar = feed(record)
      expect(calendar.to_ical).to include("DTSTART:20261022T010000Z\r\n", "TRIGGER:#{trigger}\r\n")
      expect(calendar.to_ical).not_to include("TRIGGER;VALUE=DATE-TIME:")
      expect(record.reminder_at).to eq(record.starts_at - offset)
      expect(calendar.reminder_exports).to eq([
        { id: record.id, generation: record.reminder_generation, at: record.starts_at - offset },
      ])
    end
  end

  it "advances SEQUENCE for reminder edits within a second while preserving UID" do
    record = Fabricate(:isbf_calendar_entry, user:, reminder_mode: "before_5m")
    original = feed(record).to_ical
    generation = record.reminder_generation
    record.update!(reminder_mode: "before_15m")
    edited = feed(record.reload).to_ical
    expect(record.reminder_generation).to eq(generation + 1)
    expect(original).to include("SEQUENCE:#{generation}\r\n")
    expect(edited).to include("SEQUENCE:#{generation + 1}\r\n", "TRIGGER:-PT15M\r\n")
    expect(edited.lines.grep(/^UID:/)).to eq(original.lines.grep(/^UID:/))
    expect(edited.lines.grep(/^LAST-MODIFIED:/)).to eq(original.lines.grep(/^LAST-MODIFIED:/))
  end

  it "does not export alarms for none, past, cancelled, hidden, or missing sources" do
    none = Fabricate(:isbf_calendar_entry, user:)
    past = Fabricate(
      :isbf_calendar_entry,
      user:,
      starts_at: Time.current + 1.minute,
      ends_at: Time.current + 1.hour,
      reminder_mode: "before_5m",
    )
    imported = Fabricate(:isbf_calendar_official_entry, user:, source_item: source, reminder_mode: "before_5m")
    source.update!(cancelled: true)
    expect(feed(none, past, imported).to_ical).not_to include("BEGIN:VALARM")
    expect(feed(none).to_ical).to include("SEQUENCE:#{none.reminder_generation}\r\n")
    source.update!(cancelled: false)
    topic.first_post.update!(hidden: true)
    expect(feed(imported.reload).to_ical).not_to include("BEGIN:VALARM")
    source.destroy!
    expect(feed(imported.reload).to_ical).not_to include("BEGIN:VALARM")
  end

  it "removes alarms and advances LAST-MODIFIED when the developer policy changes" do
    record = Fabricate(:isbf_calendar_entry, user:, reminder_mode: "before_5m")
    old_feed = feed(record).to_ical
    expect(old_feed).to include("BEGIN:VALARM")
    freeze_time Time.current + 1.minute
    SiteSetting.isbf_calendar_reminder_delivery_mode = "in_app"
    body = feed(record).to_ical
    expect(body).not_to include("BEGIN:VALARM")
    expect(body).to include("LAST-MODIFIED:20261019T000100Z")
    expect(old_feed.lines.grep(/^UID:/)).to eq(body.lines.grep(/^UID:/))
    SiteSetting.isbf_calendar_reminder_delivery_mode = "subscription_preferred"
    SiteSetting.isbf_calendar_reminders_enabled = false
    expect(feed(record).to_ical).not_to include("BEGIN:VALARM")
  end

  it "uses the same absolute 9am trigger and DATE convention for a personal all-day entry" do
    record = Fabricate(
      :isbf_calendar_entry,
      user:,
      all_day: true,
      starts_at: Time.utc(2026, 10, 20),
      ends_at: Time.utc(2026, 10, 21),
      reminder_mode: "same_day_9am",
      reminder_timezone: "America/New_York",
    )
    expect(feed(record).to_ical).to include(
      "DTSTART;VALUE=DATE:20261020",
      "DTEND;VALUE=DATE:20261021",
      "TRIGGER;VALUE=DATE-TIME:20261020T130000Z",
    )
  end
end
