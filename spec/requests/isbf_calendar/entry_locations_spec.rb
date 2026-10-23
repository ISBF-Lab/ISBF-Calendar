# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Calendar entry locations", type: :request do
  fab!(:owner, :user)
  fab!(:other_user, :user)
  fab!(:category)
  fab!(:topic) { Fabricate(:topic_with_op, category:) }
  fab!(:source) { Fabricate(:isbf_calendar_official_item, topic:, location: "Hall A") }

  before do
    SiteSetting.academy_roles_enabled = true
    SiteSetting.academy_official_category = category.id
    sign_in(owner)
  end

  let(:manual) do
    {
      title: "Study session", starts_at: "2026-10-24T13:00:00+08:00",
      ends_at: "2026-10-24T14:00:00+08:00", all_day: false
    }
  end

  it "persists an optional trimmed location, preserves omission and permits clearing" do
    post "/isbf/api/entries.json", params: { entry: manual.merge(location: "  Library  ") }
    expect(response.status).to eq(201)
    data = response.parsed_body.fetch("entry")
    expect(data["location"]).to eq("Library")
    id = data.fetch("id")
    patch "/isbf/api/entries/#{id}.json", params: { entry: { note: "Bring notes" } }
    expect(response.parsed_body.dig("entry", "location")).to eq("Library")
    patch "/isbf/api/entries/#{id}.json", params: { entry: { location: " " } }
    expect(response.parsed_body.dig("entry", "location")).to eq("")
    post "/isbf/api/entries.json", params: { entry: manual }
    expect(response.status).to eq(201)
    expect(response.parsed_body.dig("entry", "location")).to eq("")
  end

  it "accepts 255 characters and rejects oversized or nonscalar locations" do
    post "/isbf/api/entries.json", params: { entry: manual.merge(location: "地" * 255) }
    expect(response.status).to eq(201)
    count = IsbfCalendar::Entry.count
    ["地" * 256, ["Library"], { room: "Library" }].each do |location|
      post "/isbf/api/entries.json", params: { entry: manual.merge(location:) }
      expect(response.status).to be_between(400, 499)
      expect(IsbfCalendar::Entry.count).to eq(count)
    end
  end

  it "keeps locations private to their owner" do
    entry = Fabricate(:isbf_calendar_entry, user: other_user, location: "Private room")
    get "/isbf/api/entries/#{entry.id}.json"
    expect(response.status).to eq(404)
    patch "/isbf/api/entries/#{entry.id}.json", params: { entry: { location: "Changed" } }
    expect(response.status).to eq(404)
    expect(entry.reload.location).to eq("Private room")
  end

  it "imports a versioned location and only changes it on acceptance" do
    post "/isbf/api/official-items/#{source.id}/add.json", params: { revision: source.revision }
    expect(response.status).to eq(201)
    entry = IsbfCalendar::Entry.find(response.parsed_body.dig("entry", "id"))
    expect(entry.location).to eq("Hall A")
    entry.update!(note: "Private note")
    source.update!(location: "Hall B")
    expect(source.revision).to eq(2)
    get "/isbf/api/entries/#{entry.id}.json"
    expect(response.parsed_body.fetch("entry")).to include("location" => "Hall A", "needs_update" => true)
    patch "/isbf/api/entries/#{entry.id}.json", params: { entry: { location: "Override" } }
    expect(response.status).to eq(400)
    post "/isbf/api/entries/#{entry.id}/dismiss-update.json", params: { revision: source.revision }
    expect(response.status).to eq(204)
    expect(entry.reload.location).to eq("Hall A")
    post "/isbf/api/entries/#{entry.id}/accept-update.json", params: { revision: source.revision }
    expect(response.status).to eq(200)
    expect(entry.reload).to have_attributes(location: "Hall B", note: "Private note")
    delete "/isbf/api/entries/#{entry.id}.json"
    expect(response.status).to eq(200)
    expect(source.reload.location).to eq("Hall B")
  end

  it "reads a legacy location only from its still-visible accepted source version" do
    entry = Fabricate(:isbf_calendar_official_entry, user: owner, source_item: source, location: nil)
    get "/isbf/api/entries/#{entry.id}.json"
    expect(response.parsed_body.dig("entry", "location")).to eq("Hall A")
    expect(entry.reload.location).to be_nil
    source.update!(location: "Hall B")
    get "/isbf/api/entries/#{entry.id}.json"
    expect(response.parsed_body.dig("entry", "location")).to eq("")
    entry.update!(accepted_revision: source.revision)
    category.set_permissions(staff: :full)
    category.save!
    get "/isbf/api/entries/#{entry.id}.json"
    expect(response.parsed_body.dig("entry", "location")).to eq("")
    expect(response.body).not_to include("Hall B")
    body = IsbfCalendar::SubscriptionFeed.new(entries: [entry], guardian: owner.guardian).to_ical
    expect(body).not_to include("LOCATION:", "Hall B")
  end

  it "exports nonempty locations with native text escaping and stable UIDs" do
    entry = Fabricate(:isbf_calendar_entry, user: owner, location: "Library,room;2\\\r\nX-BAD:1")
    export = -> { IsbfCalendar::SubscriptionFeed.new(entries: [entry], guardian: owner.guardian).to_ical }
    body = export.call
    expect(body.gsub("\r\n ", "")).to include("LOCATION:Library\\,room\\;2\\\\\\nX-BAD:1")
    expect(body).not_to include("\r\nX-BAD:")
    uid = body.lines.find { |line| line.start_with?("UID:") }
    entry.update!(location: "地" * 255)
    expect(export.call).to include(uid)
    expect(export.call.split("\r\n").map(&:bytesize).max).to be <= 75
    entry.update!(location: "")
    expect(export.call).not_to include("LOCATION:")
  end
end
