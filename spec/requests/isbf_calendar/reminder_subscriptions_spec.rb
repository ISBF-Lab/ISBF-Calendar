# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Calendar subscription reminder routing" do
  fab!(:owner) { Fabricate(:user, approved: true) }
  let(:due_at) { Time.utc(2026, 10, 20, 0, 45) }

  before do
    freeze_time Time.utc(2026, 10, 19)
    SiteSetting.isbf_calendar_reminder_delivery_mode = "subscription_preferred"
  end

  def entry(**attributes)
    Fabricate(:isbf_calendar_entry, user: owner, reminder_mode: "before_15m", **attributes)
  end

  def native_key(scope: IsbfCalendar::SubscriptionFeed::SCOPE, client_id: "calendar-subscriptions")
    client = UserApiKeyClient.find_or_create_by!(client_id:) { |record| record.application_name = "Calendar subscriptions" }
    Fabricate(
      :user_api_key,
      user: owner,
      client:,
      scopes: [Fabricate.build(:user_api_key_scope, name: scope)],
    )
  end

  def fetch_feed(key)
    get "/isbf/api/calendar.ics", params: { user_api_key: key.key }
    expect(response.status).to eq(200)
  end

  def process(record)
    freeze_time due_at + 30.seconds
    2.times { Jobs::IsbfCalendarSendReminders.new.execute({}) }
    record.reload
  end

  def reminders
    Notification.where(user: owner, notification_type: Notification.types[:custom])
  end

  it "falls back to a site notification when only a subscription URL was generated" do
    record = entry
    sign_in(owner)
    post "/calendar-subscriptions.json"
    expect(response.status).to eq(200)
    expect(response.parsed_body.dig("urls", "isbf_personal")).to be_present
    process(record)
    expect(reminders.count).to eq(1)
    expect(record.reminder_delivery).to eq("in_app")
  end

  it "uses calendar once after a current VALARM was served through the native scoped key" do
    record = entry
    key = native_key
    fetch_feed(key)
    expect(response.body).to include("BEGIN:VALARM", "ACTION:DISPLAY", "TRIGGER:-PT15M\r\n")
    expect(record.reload.reminder_exported_generation).to eq(record.reminder_generation)
    expect(record.reminder_exported_key_id).to eq(key.id)
    process(record)
    expect(reminders).to be_empty
    expect(record.reminder_delivery).to eq("calendar")
    expect(record.reminder_processed_at).to be_present
    key.update!(revoked_at: Time.current)
    Jobs::IsbfCalendarSendReminders.new.execute({})
    expect(reminders).to be_empty
  end

  it "keeps an acknowledged alarm stable after it is due and processed without acknowledging it again" do
    record = entry
    key = native_key
    fetch_feed(key)
    original = response.body
    record.reload
    evidence = record.attributes.slice(
      "reminder_exported_generation", "reminder_exported_key_id", "reminder_exported_policy",
    )
    generation = record.reminder_generation

    freeze_time due_at
    fetch_feed(key)
    expect(response.body).to eq(original)
    expect(record.reload.reminder_processed_at).to be_nil
    due_calendar = IsbfCalendar::SubscriptionFeed.new(entries: [record], guardian: owner.guardian)
    expect(due_calendar.to_ical).to include("BEGIN:VALARM")
    expect(due_calendar.reminder_exports).to be_empty

    process(record)
    expect(record.reminder_delivery).to eq("calendar")
    expect(record.reminder_processed_at).to be_present
    freeze_time due_at + 1.day
    fetch_feed(key)
    expect(response.body).to eq(original)
    expect(response.body).to include("TRIGGER:-PT15M\r\n", "SEQUENCE:#{generation}\r\n")
    expect(record.reload.attributes.slice(*evidence.keys)).to eq(evidence)
    calendar = IsbfCalendar::SubscriptionFeed.new(entries: [record], guardian: owner.guardian)
    expect(calendar.to_ical).to include("BEGIN:VALARM")
    expect(calendar.reminder_exports).to be_empty
    Jobs::IsbfCalendarSendReminders.new.execute({})
    expect(reminders).to be_empty
  end

  it "retains an acknowledged all-day UTC alarm across the saved zone's DST boundary" do
    record = entry(
      all_day: true,
      starts_at: Time.utc(2026, 11, 1),
      ends_at: Time.utc(2026, 11, 2),
      reminder_mode: "same_day_9am",
      reminder_timezone: "America/New_York",
    )
    key = native_key
    fetch_feed(key)
    original = response.body
    expect(original).to include("DTSTART;VALUE=DATE:20261101", "TRIGGER;VALUE=DATE-TIME:20261101T140000Z")
    expect(record.reload.reminder_at).to eq(Time.utc(2026, 11, 1, 14))
    freeze_time record.reminder_at + 30.seconds
    2.times { Jobs::IsbfCalendarSendReminders.new.execute({}) }
    expect(record.reload.reminder_delivery).to eq("calendar")
    fetch_feed(key)
    expect(response.body).to eq(original)
    calendar = IsbfCalendar::SubscriptionFeed.new(entries: [record], guardian: owner.guardian)
    expect(calendar.to_ical).to include("TRIGGER;VALUE=DATE-TIME:20261101T140000Z")
    expect(calendar.reminder_exports).to be_empty
    expect(reminders).to be_empty
  end

  it "does not retain an old alarm after the reminder generation changes" do
    record = entry
    key = native_key
    fetch_feed(key)
    original = response.body
    old_generation = record.reload.reminder_generation
    freeze_time due_at + 30.seconds
    record.update!(reminder_mode: "before_30m")
    fetch_feed(key)
    expect(response.body).not_to include("BEGIN:VALARM")
    expect(response.body).to include("SEQUENCE:#{old_generation + 1}\r\n")
    expect(response.body.lines.grep(/^UID:/)).to eq(original.lines.grep(/^UID:/))
    expect(record.reload.reminder_exported_generation).to be_nil
  end

  it "does not retain an acknowledged past alarm after the delivery policy changes" do
    record = entry
    key = native_key
    fetch_feed(key)
    freeze_time due_at + 30.seconds
    SiteSetting.isbf_calendar_reminder_delivery_mode = "in_app"
    SiteSetting.isbf_calendar_reminder_delivery_mode = "subscription_preferred"
    fetch_feed(key)
    expect(response.body).not_to include("BEGIN:VALARM")
  end

  %w[none disabled in_app].each do |state|
    it "removes an acknowledged past alarm when reminders become #{state}" do
      record = entry
      key = native_key
      fetch_feed(key)
      freeze_time due_at + 30.seconds
      case state
      when "none"
        record.update!(reminder_mode: "none")
      when "disabled"
        SiteSetting.isbf_calendar_reminders_enabled = false
      when "in_app"
        SiteSetting.isbf_calendar_reminder_delivery_mode = "in_app"
      end
      fetch_feed(key)
      expect(response.body).not_to include("BEGIN:VALARM")
    end
  end

  %w[cancelled hidden missing].each do |state|
    it "removes an acknowledged past alarm when its official source becomes #{state}" do
      category = Fabricate(:category)
      topic = Fabricate(:topic_with_op, category:)
      source = Fabricate(:isbf_calendar_official_item, topic:)
      allow(IsbfCalendar).to receive(:official_category_id).and_return(category.id)
      record = Fabricate(:isbf_calendar_official_entry, user: owner, source_item: source, reminder_mode: "before_15m")
      key = native_key
      fetch_feed(key)
      expect(response.body).to include("BEGIN:VALARM")
      expect(record.reload.reminder_exported_generation).to eq(record.reminder_generation)
      freeze_time due_at + 30.seconds
      case state
      when "cancelled"
        source.update!(cancelled: true)
      when "hidden"
        topic.first_post.update!(hidden: true)
      when "missing"
        source.destroy!
      end
      fetch_feed(key)
      expect(response.body).not_to include("BEGIN:VALARM")
    end
  end

  it "does not count a browser session ICS download as native subscription consumption" do
    record = entry
    native_key
    sign_in(owner)
    get "/isbf/api/calendar.ics"
    expect(response.status).to eq(200)
    expect(response.body).to include("BEGIN:VALARM")
    expect(record.reload.reminder_exported_generation).to be_nil
    process(record)
    expect(reminders.count).to eq(1)
    get "/isbf/api/calendar.ics"
    expect(response.status).to eq(200)
    expect(response.body).not_to include("BEGIN:VALARM")
  end

  %w[revoked expired scope_removed].each do |state|
    it "falls back when the exporting key becomes #{state}" do
      record = entry
      key = native_key
      fetch_feed(key)
      case state
      when "revoked"
        key.update!(revoked_at: Time.current)
      when "expired"
        key.update!(expires_at: Time.current)
      when "scope_removed"
        key.scopes.destroy_all
      end
      process(record)
      expect(reminders.count).to eq(1)
      expect(record.reminder_delivery).to eq("in_app")
      calendar = IsbfCalendar::SubscriptionFeed.new(entries: [record], guardian: owner.guardian)
      expect(calendar.to_ical).not_to include("BEGIN:VALARM")
      expect(calendar.reminder_exports).to be_empty
    end
  end

  it "does not transfer export evidence to a rotated key or unrelated calendar key" do
    record = entry
    key = native_key
    fetch_feed(key)
    key.update!(revoked_at: Time.current)
    native_key
    native_key(scope: "bookmarks_calendar")
    process(record)
    expect(reminders.count).to eq(1)
    expect(record.reminder_delivery).to eq("in_app")
  end

  it "does not use an arbitrary app's key as calendar subscription evidence" do
    record = entry
    fetch_feed(native_key(client_id: "some-other-app"))
    expect(response.body).to include("BEGIN:VALARM")
    expect(record.reload.reminder_exported_generation).to be_nil
    process(record)
    expect(reminders.count).to eq(1)
  end

  it "rejects a native key for another feed and leaves reminders in fallback mode" do
    record = entry
    key = native_key(scope: "bookmarks_calendar")
    get "/isbf/api/calendar.ics", params: { user_api_key: key.key }
    expect(response.status).to eq(403)
    process(record)
    expect(reminders.count).to eq(1)
  end

  it "rejects an old feed acknowledgment after a concurrent schedule edit" do
    record = entry
    key = native_key
    feed = IsbfCalendar::SubscriptionFeed.new(entries: [record], guardian: owner.guardian)
    feed.to_ical
    record.update!(reminder_mode: "before_30m")
    IsbfCalendar::Reminders.acknowledge_exports(
      user: owner,
      key:,
      snapshots: feed.reminder_exports,
      policy_version: feed.reminder_policy_version,
    )
    expect(record.reload.reminder_exported_generation).to be_nil
    freeze_time record.reminder_at
    Jobs::IsbfCalendarSendReminders.new.execute({})
    expect(reminders.count).to eq(1)
  end

  it "invalidates acknowledged and in-flight feeds when developer policy changes" do
    record = entry
    key = native_key
    fetch_feed(key)
    old_policy = record.reload.reminder_exported_policy
    feed = IsbfCalendar::SubscriptionFeed.new(entries: [record], guardian: owner.guardian)
    feed.to_ical
    freeze_time Time.current + 1.minute
    SiteSetting.isbf_calendar_reminder_delivery_mode = "in_app"
    SiteSetting.isbf_calendar_reminder_delivery_mode = "subscription_preferred"
    expect(IsbfCalendar::Reminders.policy_version).not_to eq(old_policy)
    IsbfCalendar::Reminders.acknowledge_exports(
      user: owner, key:, snapshots: feed.reminder_exports, policy_version: feed.reminder_policy_version,
    )
    process(record)
    expect(reminders.count).to eq(1)
  end
end
