# frozen_string_literal: true

module Jobs
  class IsbfCalendarSendReminders < ::Jobs::Scheduled
    every 1.minute

    def execute(_args)
      return unless IsbfCalendar::Reminders.enabled?

      now = Time.current
      IsbfCalendar::Entry
        .where(reminder_processed_at: nil)
        .where("reminder_at <= ?", now)
        .find_each(batch_size: 100) do |entry|
          IsbfCalendar::Reminders.process!(entry, now: Time.current)
        end
    end
  end
end
