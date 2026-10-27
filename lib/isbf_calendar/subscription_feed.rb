# frozen_string_literal: true

module IsbfCalendar
  class SubscriptionFeed
    NAME = "isbf_personal"
    SCOPE = "isbf-calendar:personal_calendar"
    ACTION = "isbf_calendar/subscriptions#show"

    attr_reader :reminder_exports, :reminder_policy_version

    def initialize(entries:, guardian:)
      @entries = entries
      @guardian = guardian
      @reminder_exports = []
      policy = Reminders.policy
      @reminder_policy_version = policy["version"].to_s
      stamp = policy["modified_at"] || policy["changed_at"]
      @reminder_policy_changed_at = Time.iso8601(stamp) if stamp
    end

    def to_ical
      @reminder_exports.clear
      @generated_at = Time.current
      @active_key_ids = nil
      lines = [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//ISBF//Personal Calendar//EN",
        "CALSCALE:GREGORIAN",
        "X-WR-CALNAME:#{text(I18n.t("isbf_calendar.subscription_name"))}",
        "X-WR-CALDESC:#{text(I18n.t("isbf_calendar.subscription_window"))}",
      ]
      @entries.each { |entry| lines.concat(event(entry)) }
      lines << "END:VCALENDAR"
      lines.flat_map { |line| fold(line) }.join("\r\n") + "\r\n"
    end

    private

    def event(entry)
      source = entry.source_item
      cancelled = source&.cancelled?
      modified = cancelled ? [entry.updated_at, source.updated_at].max : entry.updated_at
      modified = [modified, @reminder_policy_changed_at].compact.max
      lines = [
        "BEGIN:VEVENT",
        "UID:isbf-personal-#{entry.user_id}-#{entry.id}@#{Discourse.current_hostname}",
        "SEQUENCE:#{entry.reminder_generation}",
        "CREATED:#{timestamp(entry.created_at)}",
        "LAST-MODIFIED:#{timestamp(modified)}",
        "DTSTAMP:#{timestamp(modified)}",
        "SUMMARY:#{text(entry.title)}",
      ]
      if entry.all_day?
        # Official snapshots store Shanghai midnight; manual date entries store UTC dates.
        zone = entry.source_item_id ? IsbfCalendar::TIMEZONE : "UTC"
        lines << "DTSTART;VALUE=DATE:#{entry.starts_at.in_time_zone(zone).strftime("%Y%m%d")}"
        lines << "DTEND;VALUE=DATE:#{entry.ends_at.in_time_zone(zone).strftime("%Y%m%d")}"
      else
        lines << "DTSTART:#{timestamp(entry.starts_at)}"
        lines << "DTEND:#{timestamp(entry.ends_at)}" if entry.ends_at > entry.starts_at
      end
      lines << "DESCRIPTION:#{text(entry.note)}" if entry.note.present?
      location = entry.effective_location(@guardian)
      lines << "LOCATION:#{text(location)}" if location.present?
      lines << "STATUS:CANCELLED" if cancelled
      if source&.visible_to?(@guardian)
        lines << "URL:#{IcalEncoder.encode_uri(source.topic.url)}"
      end
      fresh_alarm = Reminders.exportable?(entry, @guardian, now: @generated_at)
      # Keep an already exported alarm stable when its due job runs.
      retained_alarm =
        !fresh_alarm && Reminders.subscription_preferred? && entry.reminder_at &&
          entry.reminder_at <= @generated_at &&
          Reminders.retained_alarm?(entry, @guardian, now: @generated_at, active_key_ids: active_key_ids)
      if fresh_alarm || retained_alarm
        lines.concat([
          "BEGIN:VALARM",
          "ACTION:DISPLAY",
          alarm_trigger(entry),
          "DESCRIPTION:#{text(entry.title)}",
          "END:VALARM",
        ])
        if fresh_alarm
          @reminder_exports << {
            id: entry.id,
            generation: entry.reminder_generation,
            at: entry.reminder_at,
          }
        end
      end
      lines << "END:VEVENT"
    end

    def active_key_ids
      @active_key_ids ||= Reminders.native_keys(@guardian.user.id).distinct.pluck(:id)
    end

    def alarm_trigger(entry)
      return "TRIGGER;VALUE=DATE-TIME:#{timestamp(entry.reminder_at)}" if entry.all_day?

      seconds = Reminders::TIMED_OFFSETS.fetch(entry.reminder_mode).to_i
      duration = seconds % 3600 == 0 ? "#{seconds / 3600}H" : "#{seconds / 60}M"
      "TRIGGER:-PT#{duration}"
    end

    def timestamp(value)
      value.utc.strftime("%Y%m%dT%H%M%SZ")
    end

    def text(value)
      # Normalize lone CR too, including entity-encoded CR after native decoding.
      IcalEncoder.encode(value.to_s.gsub("\r\n", "\n").gsub("\r", "\n")).to_s.gsub("\r", "\\n")
    end

    def fold(line)
      result = []
      current = +""
      line.each_char do |character|
        if current.bytesize + character.bytesize > 75
          result << current
          current = +" "
        end
        current << character
      end
      result << current
    end
  end
end
