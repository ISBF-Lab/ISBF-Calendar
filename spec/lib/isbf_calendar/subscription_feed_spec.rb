# frozen_string_literal: true

require "rails_helper"

RSpec.describe IsbfCalendar::SubscriptionFeed do
  fab!(:user)

  def export(*entries)
    described_class.new(entries:, guardian: user.guardian).to_ical
  end

  it "uses UTC stored timestamps and stable identities across exports and edits" do
    entry = Fabricate(:isbf_calendar_entry, user:, created_at: Time.utc(2026, 1, 1), updated_at: Time.utc(2026, 2, 1))
    body = export(entry)
    expect(body).to include(
      "UID:isbf-personal-#{user.id}-#{entry.id}@#{Discourse.current_hostname}",
      "CREATED:20260101T000000Z", "LAST-MODIFIED:20260201T000000Z",
      "DTSTAMP:20260201T000000Z", "DTSTART:20261020T010000Z", "DTEND:20261020T020000Z"
    )
    freeze_time(2.days.from_now) { expect(export(entry)).to eq(body) }
    uid = body.lines.find { |line| line.start_with?("UID:") }
    entry.update!(title: "Updated title", note: "Updated note")
    expect(export(entry)).to include(uid, "SUMMARY:Updated title", "DESCRIPTION:Updated note")
  end

  it "uses exclusive DATE ends and keeps deadlines as exact points" do
    manual = Fabricate(:isbf_calendar_entry, user:, all_day: true, starts_at: Time.utc(2026, 10, 20), ends_at: Time.utc(2026, 10, 22))
    official_source = Fabricate(:isbf_calendar_official_item, all_day: true, starts_at: Time.iso8601("2026-10-20T00:00:00+08:00"), ends_at: Time.iso8601("2026-10-21T00:00:00+08:00"))
    official = Fabricate(:isbf_calendar_official_entry, user:, source_item: official_source)
    deadline_source = Fabricate(:isbf_calendar_official_deadline)
    deadline = Fabricate(:isbf_calendar_official_entry, user:, source_item: deadline_source)
    expect(export(manual)).to include("DTSTART;VALUE=DATE:20261020", "DTEND;VALUE=DATE:20261022")
    expect(export(official)).to include("DTSTART;VALUE=DATE:20261020", "DTEND;VALUE=DATE:20261021")
    expect(export(deadline)).to include("DTSTART:20261019T100000Z")
    expect(export(deadline)).not_to include("DTEND:")
  end

  it "escapes text and folds UTF-8 without permitting CRLF property injection" do
    entry = Fabricate(:isbf_calendar_entry, user:, title: "中文" * 55, note: "<b>Private</b>,semi;slash\\\r\nBEGIN:VEVENT\rX-BAD:1&#13;&#10;X-ENTITY:2")
    body = export(entry)
    expect(body).to be_valid_encoding
    expect(body.split("\r\n").map(&:bytesize).max).to be <= 75
    expect(body.delete("\r\n")).not_to include("<b>")
    expect(body.scan("BEGIN:VEVENT\r\n").size).to eq(1)
    expect(body).not_to match(/\r\n(?:X-BAD|X-ENTITY):/)
    expect(body.gsub("\r\n ", "")).to include("SUMMARY:#{entry.title}", "Private\\,semi\\;slash\\\\\\nBEGIN:VEVENT\\nX-BAD:1")
    expect(body.gsub("\r\n", "")).not_to match(/[\r\n]/)
  end
end
