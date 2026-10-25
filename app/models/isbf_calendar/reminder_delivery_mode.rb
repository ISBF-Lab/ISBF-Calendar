# frozen_string_literal: true

require "enum_site_setting"

module IsbfCalendar
  class ReminderDeliveryMode < ::EnumSiteSetting
    def self.valid_value?(value)
      values.any? { |entry| entry[:value] == value }
    end

    def self.values
      [
        { name: "isbf_calendar.delivery_modes.in_app", value: "in_app" },
        { name: "isbf_calendar.delivery_modes.subscription_preferred", value: "subscription_preferred" },
      ]
    end

    def self.translate_names?
      true
    end
  end
end
