# frozen_string_literal: true

require "rails_helper"

RSpec.describe IsbfCalendar::SubscriptionsController do
  fab!(:owner, :user)
  fab!(:other_user, :user)
  fab!(:category)
  fab!(:topic) { Fabricate(:topic_with_op, category:) }
  fab!(:source) { Fabricate(:isbf_calendar_official_item, topic:) }

  before do
    freeze_time Time.utc(2026, 10, 15)
    allow(IsbfCalendar).to receive(:official_category_id).and_return(category.id)
  end

  def scoped_key(user = owner, scope = IsbfCalendar::SubscriptionFeed::SCOPE)
    Fabricate(
      :user_api_key,
      user:,
      scopes: [Fabricate.build(:user_api_key_scope, name: scope)]
    )
  end

  def fetch_feed(key = nil, **params)
    params[:user_api_key] = key.key if key
    get "/isbf/api/calendar.ics", params:
  end

  it "requires authentication and permits an empty calendar" do
    fetch_feed
    expect(response.status).not_to eq(200)
    sign_in(owner)
    fetch_feed
    expect(response.status).to eq(200)
    expect(response.body).to include("BEGIN:VCALENDAR\r\n", "END:VCALENDAR\r\n")
    expect(response.body).not_to include("BEGIN:VEVENT")
    expect(response.headers["Cache-Control"]).to include("private", "no-store")
    expect(response.media_type).to eq("text/calendar")
  end

  it "authenticates a scoped key without a session and ignores user selectors" do
    own = Fabricate(:isbf_calendar_entry, user: owner, note: "Private note")
    Fabricate(:isbf_calendar_entry, user: other_user, title: "Other user's secret")
    key = scoped_key
    fetch_feed(key, user_id: other_user.id, username: other_user.username)
    expect(response.status).to eq(200)
    expect(response.body).to include("SUMMARY:#{own.title}", "DESCRIPTION:Private note")
    expect(response.body).not_to include("Other user's secret", key.key)
  end

  it "rejects invalid, revoked, and unrelated scoped keys" do
    get "/isbf/api/calendar.ics", params: { user_api_key: "invalid-key" }
    expect(response.status).to eq(403)
    key = scoped_key
    key.update!(revoked_at: Time.current)
    fetch_feed(key)
    expect(response.status).to eq(403)
    fetch_feed(scoped_key(owner, "bookmarks_calendar"))
    expect(response.status).to eq(403)
  end

  it "does not allow JSON, writes, or other personal API routes with the feed key" do
    key = scoped_key
    get "/isbf/api/calendar.json", params: { user_api_key: key.key }
    expect(response.status).not_to eq(200)
    post "/isbf/api/calendar.ics", params: { user_api_key: key.key }
    expect(response.status).not_to be_between(200, 299)
    get "/isbf/api/entries.json",
        headers: { "User-Api-Key" => key.key },
        params: { from: "2026-10-01T00:00:00Z", to: "2026-11-01T00:00:00Z" }
    expect(response.status).to eq(403)
    expect do
      post "/isbf/api/entries.json",
           headers: { "User-Api-Key" => key.key },
           params: { entry: { title: "Forbidden" } }
    end.not_to change(IsbfCalendar::Entry, :count)
    expect(response.status).to eq(403)
  end

  it "keeps saved official snapshots until accepted and keeps UID through updates" do
    entry = Fabricate(:isbf_calendar_official_entry, user: owner, source_item: source, note: "My note")
    key = scoped_key
    fetch_feed(key)
    uid = response.body.lines.find { |line| line.start_with?("UID:") }
    source.update!(title: "Changed source", starts_at: source.starts_at + 1.day, ends_at: source.ends_at + 1.day)
    fetch_feed(key)
    expect(response.body).to include("SUMMARY:Campus briefing", uid, "DESCRIPTION:My note")
    expect(response.body).not_to include("Changed source")
    entry.update!(source.snapshot.merge(accepted_revision: source.revision))
    fetch_feed(key)
    expect(response.body).to include("SUMMARY:Changed source", uid)
    entry.destroy!
    fetch_feed(key)
    expect(response.body).not_to include("BEGIN:VEVENT", uid)
  end

  it "retains cancelled snapshots and suppresses URLs and new source data after lost access" do
    Fabricate(:isbf_calendar_official_entry, user: owner, source_item: source)
    key = scoped_key
    fetch_feed(key)
    expect(response.body).to include("URL:")
    source.update!(cancelled: true, title: "New restricted title", location: "Private hall", organizer: "Private host")
    topic.first_post.update!(hidden: true)
    fetch_feed(key)
    expect(response.body).to include("SUMMARY:Campus briefing", "STATUS:CANCELLED")
    expect(response.body).not_to include("URL:", "New restricted title", "Private hall", "Private host")
    topic.first_post.update!(hidden: false)
    category.set_permissions(staff: :full)
    category.save!
    fetch_feed(key)
    expect(response.body).not_to include("URL:")
    topic.update!(deleted_at: Time.current)
    fetch_feed(key)
    expect(response.body).not_to include("URL:")
  end

  it "exports every overlapping record in the disclosed rolling window" do
    Fabricate(:isbf_calendar_entry, user: owner, title: "Too old", starts_at: 2.years.ago, ends_at: 2.years.ago + 1.hour)
    Fabricate(:isbf_calendar_entry, user: owner, title: "Too far", starts_at: 3.years.from_now, ends_at: 3.years.from_now + 1.hour)
    105.times { Fabricate(:isbf_calendar_entry, user: owner) }
    fetch_feed(scoped_key)
    expect(response.body.scan("BEGIN:VEVENT").length).to eq(105)
    expect(response.body).to include("X-WR-CALDESC:")
    expect(response.body).not_to include("Too old", "Too far")
  end

  it "registers native subscription scopes, URLs and site capability" do
    sign_in(owner)
    get "/site.json"
    expect(response.parsed_body.dig("isbf_calendar", "subscription_feed")).to eq("isbf_personal")
    post "/calendar-subscriptions.json"
    expect(response.status).to eq(200)
    body = response.parsed_body
    expect(body.dig("urls", "isbf_personal")).to eq("#{Discourse.base_url}/isbf/api/calendar.ics?user_api_key=#{body["key"]}")
    expect(UserApiKey.active.where(user_id: owner.id).last.scopes.map(&:name)).to include(IsbfCalendar::SubscriptionFeed::SCOPE)
    delete "/calendar-subscriptions.json"
    sign_out
    get "/isbf/api/calendar.ics", params: { user_api_key: body["key"] }
    expect(response.status).to eq(403)
  end
end
