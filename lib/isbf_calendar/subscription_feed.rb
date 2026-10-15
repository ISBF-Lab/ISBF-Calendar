# frozen_string_literal: true

module IsbfCalendar
  class SubscriptionFeed
    NAME = "isbf_personal"
    SCOPE = "isbf-calendar:personal_calendar"
    ACTION = "isbf_calendar/subscriptions#show"

    def initialize(entries:, guardian:)
      @entries = entries
      @guardian = guardian
    end

    def to_ical
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
      lines = [
        "BEGIN:VEVENT",
        "UID:isbf-personal-#{entry.user_id}-#{entry.id}@#{Discourse.current_hostname}",
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
      lines << "STATUS:CANCELLED" if cancelled
      if source&.visible_to?(@guardian)
        lines << "URL:#{IcalEncoder.encode_uri(source.topic.url)}"
      end
      lines << "END:VEVENT"
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
