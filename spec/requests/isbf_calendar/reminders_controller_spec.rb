# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Personal calendar reminder API" do
  fab!(:owner) { Fabricate(:user, approved: true) }
  fab!(:other_user, :user)
  fab!(:category)
  fab!(:topic) { Fabricate(:topic_with_op, category:) }
  fab!(:source) { Fabricate(:isbf_calendar_official_item, topic:) }

  before do
    freeze_time Time.utc(2026, 10, 1)
    allow(IsbfCalendar).to receive(:official_category_id).and_return(category.id)
    sign_in(owner)
  end

  let(:attributes) do
    {
      title: "Library",
      starts_at: "2026-10-20T09:00:00+08:00",
      ends_at: "2026-10-20T10:00:00+08:00",
      all_day: false,
      reminder_mode: "before_15m",
      reminder_timezone: "Asia/Shanghai",
    }
  end

  it "advertises the supported settings and modes through site metadata" do
    get "/site.json"
    expect(response.parsed_body.dig("isbf_calendar", "reminders")).to eq(
      "enabled" => true,
      "delivery_mode" => "in_app",
      "timed_modes" => IsbfCalendar::Reminders::TIMED_MODES,
      "all_day_modes" => IsbfCalendar::Reminders::ALL_DAY_MODES,
    )
  end

  it "creates, serializes, preserves omitted fields, and clears a reminder" do
    post "/isbf/api/entries.json", params: { entry: attributes }
    expect(response.status).to eq(201)
    data = response.parsed_body.fetch("entry")
    expect(data).to include(
      "reminder_mode" => "before_15m",
      "reminder_timezone" => "Asia/Shanghai",
      "reminder_delivery" => "in_app",
    )
    expect(Time.iso8601(data["reminder_at"])).to eq(Time.utc(2026, 10, 20, 0, 45))
    id = data.fetch("id")
    record = IsbfCalendar::Entry.find(id)
    generation = record.reminder_generation
    patch "/isbf/api/entries/#{id}.json", params: { entry: { note: "Private" } }
    expect(response.status).to eq(200)
    expect(record.reload.reminder_generation).to eq(generation)
    patch "/isbf/api/entries/#{id}.json", params: { entry: { reminder_mode: "none" } }
    expect(response.status).to eq(200)
    expect(response.parsed_body["entry"]).to include(
      "reminder_mode" => "none",
      "reminder_at" => nil,
      "reminder_delivery" => nil,
    )
  end

  it "rejects unknown modes, invalid zones, malformed values, and timezone-less instants" do
    [
      { reminder_mode: "before_3m" },
      { reminder_timezone: "No/Such_Zone" },
      { reminder_mode: ["before_5m"] },
      { reminder_timezone: { zone: "UTC" } },
      { reminder_mode: nil },
      { starts_at: "2026-10-20T09:00:00" },
    ].each do |invalid|
      expect {
        post "/isbf/api/entries.json", params: { entry: attributes.merge(invalid) }
      }.not_to change(IsbfCalendar::Entry, :count)
      expect(response.status).not_to eq(201)
    end
  end

  it "never allows another user's reminder to be changed or read" do
    record = Fabricate(:isbf_calendar_entry, user: other_user)
    patch "/isbf/api/entries/#{record.id}.json", params: { entry: { reminder_mode: "before_5m" } }
    expect(response.status).to eq(404)
    get "/isbf/api/entries/#{record.id}.json"
    expect(response.status).to eq(404)
  end

  it "imports an official snapshot and reminder together and preserves duplicate requests" do
    post "/isbf/api/official-items/#{source.id}/add.json",
         params: { revision: source.revision, reminder_mode: "before_5m" }
    expect(response.status).to eq(201)
    record = IsbfCalendar::Entry.find(response.parsed_body.dig("entry", "id"))
    expect(record.reminder_mode).to eq("before_5m")
    generation = record.reminder_generation
    post "/isbf/api/official-items/#{source.id}/add.json",
         params: { revision: source.revision, reminder_mode: "before_1h" }
    expect(response.status).to eq(200)
    expect(record.reload.reminder_mode).to eq("before_5m")
    expect(record.reminder_generation).to eq(generation)
    patch "/isbf/api/entries/#{record.id}.json",
          params: { entry: { note: "My note", reminder_mode: "before_30m" } }
    expect(response.status).to eq(200)
    patch "/isbf/api/entries/#{record.id}.json", params: { entry: { title: "Override" } }
    expect(response.status).to eq(400)
    expect(record.reload.title).to eq(source.title)
  end

  it "rolls back a new official import with an invalid reminder" do
    expect {
      post "/isbf/api/official-items/#{source.id}/add.json",
           params: { revision: source.revision, reminder_mode: "same_day_9am" }
    }.not_to change(IsbfCalendar::Entry, :count)
    expect(response.status).not_to eq(201)
  end

  it "replans accepted source updates but keeps a dismissed snapshot and its reminder" do
    record = Fabricate(:isbf_calendar_official_entry, user: owner, source_item: source, reminder_mode: "before_15m")
    original_at = record.reminder_at
    generation = record.reminder_generation
    source.update!(starts_at: source.starts_at + 1.day, ends_at: source.ends_at + 1.day)
    post "/isbf/api/entries/#{record.id}/dismiss-update.json", params: { revision: source.revision }
    expect(response.status).to eq(204)
    expect(record.reload.reminder_at).to eq(original_at)
    expect(record.reminder_generation).to eq(generation)
    post "/isbf/api/entries/#{record.id}/accept-update.json", params: { revision: source.revision }
    expect(response.status).to eq(200)
    expect(record.reload.reminder_at).to eq(original_at + 1.day)
    expect(record.reminder_generation).to eq(generation + 1)
  end

  it "keeps reminder state when accepting only source title, location, or end-time changes" do
    record = Fabricate(:isbf_calendar_official_entry, user: owner, source_item: source, reminder_mode: "before_15m")
    record.update_columns(
      reminder_processed_at: Time.current,
      reminder_delivery: "calendar",
      reminder_exported_generation: record.reminder_generation,
      reminder_exported_key_id: 123,
      reminder_exported_policy: "exported-policy",
    )
    previous = record.attributes.slice(*record.attributes.keys.grep(/^reminder_/))
    [
      { location: "Updated hall" },
      { title: "Updated title" },
      { ends_at: source.ends_at + 1.hour },
    ].each do |change|
      source.update!(change)
      post "/isbf/api/entries/#{record.id}/accept-update.json", params: { revision: source.revision }
      expect(response.status).to eq(200)
      expect(record.reload).to have_attributes(
        title: source.title,
        location: source.location,
        ends_at: source.ends_at,
        accepted_revision: source.revision,
      )
      expect(record.attributes.slice(*previous.keys)).to eq(previous)
    end
  end
  it "allows only native admins to change the single delivery policy" do
    put "/admin/site_settings/isbf_calendar_reminder_delivery_mode.json",
        params: { isbf_calendar_reminder_delivery_mode: "subscription_preferred" }
    expect(response.status).to be_in([403, 404])
    expect(SiteSetting.isbf_calendar_reminder_delivery_mode).to eq("in_app")
    sign_out
    sign_in(Fabricate(:moderator))
    put "/admin/site_settings/isbf_calendar_reminders_enabled.json",
        params: { isbf_calendar_reminders_enabled: false }
    expect(response.status).to be_in([403, 404])
    sign_out
    sign_in(Fabricate(:admin))
    put "/admin/site_settings/isbf_calendar_reminder_delivery_mode.json",
        params: { isbf_calendar_reminder_delivery_mode: "subscription_preferred" }
    expect(response.status).to eq(200)
    expect(SiteSetting.isbf_calendar_reminder_delivery_mode).to eq("subscription_preferred")
    put "/admin/site_settings/isbf_calendar_reminder_delivery_mode.json",
        params: { isbf_calendar_reminder_delivery_mode: "both" }
    expect(response.status).not_to eq(200)
    expect(SiteSetting.isbf_calendar_reminder_delivery_mode).to eq("subscription_preferred")
  end
end
