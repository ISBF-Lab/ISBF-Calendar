# frozen_string_literal: true

require "rails_helper"

RSpec.describe Jobs::IsbfCalendarSendReminders do
  fab!(:user) { Fabricate(:user, approved: true) }
  let(:due_at) { Time.utc(2026, 10, 20, 0, 45) }

  before do
    freeze_time Time.utc(2026, 10, 19)
    SiteSetting.isbf_calendar_reminders_enabled = true
    SiteSetting.isbf_calendar_reminder_delivery_mode = "in_app"
  end

  def new_entry(**attributes)
    Fabricate(:isbf_calendar_entry, user:, reminder_mode: "before_15m", **attributes)
  end

  def notifications
    Notification.where(user:, notification_type: Notification.types[:custom])
  end

  def run_at(time)
    freeze_time time
    described_class.new.execute({})
  end

  it "sends one native custom notification and prevents retry duplicates" do
    record = new_entry
    expect(Notification).to receive(:create!).with(hash_including(skip_send_email: true)).once.and_call_original
    run_at(due_at + 30.seconds)
    run_at(due_at + 1.minute)
    expect(notifications.count).to eq(1)
    expect(notifications.first.data_hash).to include(
      "message" => "isbf_calendar.reminder",
      "entry_id" => record.id,
      "topic_title" => record.title,
    )
    expect(record.reload.reminder_delivery).to eq("in_app")
  end

  it "serializes stale worker snapshots through a row lock" do
    record = new_entry
    first_worker = IsbfCalendar::Entry.find(record.id)
    second_worker = IsbfCalendar::Entry.find(record.id)
    freeze_time due_at
    IsbfCalendar::Reminders.process!(first_worker, now: Time.current)
    IsbfCalendar::Reminders.process!(second_worker, now: Time.current)
    expect(notifications.count).to eq(1)
    expect(second_worker.reminder_processed_at).to eq(Time.current)
  end

  it "rolls the notification back with a failed processed marker and safely retries" do
    record = new_entry
    freeze_time due_at
    allow(record).to receive(:update_columns).and_raise("simulated marker failure")
    expect {
      IsbfCalendar::Reminders.process!(record, now: Time.current)
    }.to raise_error("simulated marker failure")
    expect(notifications).to be_empty
    expect(record.reload.reminder_processed_at).to be_nil
    described_class.new.execute({})
    expect(notifications.count).to eq(1)
  end

  it "skips reminders configured after their trigger, expired catch-up, and ended anchors" do
    expired = new_entry
    ended = new_entry(
      starts_at: due_at - 1.minute,
      ends_at: due_at + 1.hour,
      reminder_mode: "before_5m",
    )
    freeze_time due_at + 1.minute
    past = new_entry
    run_at(due_at + 11.minutes)
    expect(notifications).to be_empty
    expect(expired.reload.reminder_processed_at).to be_present
    expect(ended.reload.reminder_delivery).to be_nil
    expect(past.reload.reminder_delivery).to be_nil
  end

  it "does not catch up reminders that passed while globally disabled" do
    record = new_entry
    SiteSetting.isbf_calendar_reminders_enabled = false
    run_at(due_at)
    expect(record.reload.reminder_processed_at).to be_nil
    freeze_time due_at + 1.minute
    SiteSetting.isbf_calendar_reminders_enabled = true
    described_class.new.execute({})
    expect(notifications).to be_empty
    expect(record.reload.reminder_processed_at).to be_present
  end

  it "suppresses inactive, unapproved, staged, or suspended users" do
    [
      { active: false },
      { approved: false },
      { staged: true },
      { suspended_till: 1.year.from_now },
    ].each do |state|
      recipient = Fabricate(:user, approved: true)
      recipient.update_columns(**state)
      new_entry(user: recipient)
    end
    run_at(due_at)
    expect(Notification.where(notification_type: Notification.types[:custom])).to be_empty
  end

  it "withholds cancelled, hidden, deleted, or inaccessible official sources" do
    category = Fabricate(:category)
    allow(IsbfCalendar).to receive(:official_category_id).and_return(category.id)
    [
      ->(source) { source.update!(cancelled: true) },
      ->(source) { source.topic.first_post.update!(hidden: true) },
      ->(source) { source.topic.update!(deleted_at: Time.current) },
      ->(source) { source.destroy! },
    ].each do |mutate|
      source = Fabricate(:isbf_calendar_official_item, topic: Fabricate(:topic_with_op, category:))
      Fabricate(:isbf_calendar_official_entry, user:, source_item: source, reminder_mode: "before_15m")
      mutate.call(source)
    end
    inaccessible = Fabricate(:category)
    source = Fabricate(:isbf_calendar_official_item, topic: Fabricate(:topic_with_op, category: inaccessible))
    Fabricate(:isbf_calendar_official_entry, user:, source_item: source, reminder_mode: "before_15m")
    inaccessible.set_permissions(staff: :full)
    inaccessible.save!
    run_at(due_at)
    expect(notifications).to be_empty
  end

  it "handles all-day 9am within the same local date and the catch-up window" do
    record = new_entry(
      all_day: true,
      starts_at: Time.utc(2026, 10, 20),
      ends_at: Time.utc(2026, 10, 21),
      reminder_mode: "same_day_9am",
      reminder_timezone: "Asia/Shanghai",
    )
    run_at(Time.utc(2026, 10, 20, 1, 5))
    expect(notifications.count).to eq(1)
    expect(record.reload.reminder_delivery).to eq("in_app")
  end
end
