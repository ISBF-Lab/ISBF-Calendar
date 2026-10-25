# frozen_string_literal: true

module IsbfCalendar
  module Reminders
    TIMED_OFFSETS = {
      "before_5m" => 5.minutes,
      "before_15m" => 15.minutes,
      "before_30m" => 30.minutes,
      "before_1h" => 1.hour,
      "before_24h" => 24.hours,
    }.freeze
    TIMED_MODES = (["none"] + TIMED_OFFSETS.keys).freeze
    ALL_DAY_MODES = %w[none same_day_9am previous_day_9am].freeze
    SETTINGS = %i[isbf_calendar_reminders_enabled isbf_calendar_reminder_delivery_mode].freeze
    CATCHUP = 10.minutes

    def self.enabled?
      SiteSetting.isbf_calendar_reminders_enabled
    end

    def self.subscription_preferred?
      enabled? && SiteSetting.isbf_calendar_reminder_delivery_mode == "subscription_preferred"
    end

    def self.metadata
      {
        enabled: enabled?,
        delivery_mode: SiteSetting.isbf_calendar_reminder_delivery_mode,
        timed_modes: TIMED_MODES,
        all_day_modes: ALL_DAY_MODES,
      }
    end

    def self.policy
      PluginStore.get(PLUGIN_NAME, "reminder_policy") || {}
    end

    def self.policy_version
      policy["version"].to_s
    end

    def self.policy_changed_at
      value = policy["changed_at"]
      Time.iso8601(value) if value
    end

    def self.policy_changed!
      now = Time.current
      previous = policy
      previous_stamp = previous["modified_at"] || previous["changed_at"]
      modified_at = previous_stamp ? [now, Time.iso8601(previous_stamp) + 1.second].max : now
      PluginStore.set(
        PLUGIN_NAME,
        "reminder_policy",
        { version: SecureRandom.uuid, changed_at: now.iso8601(6), modified_at: modified_at.iso8601(6) },
      )
    end

    def self.attributes_from_payload(raw)
      %w[reminder_mode reminder_timezone].each_with_object({}) do |name, attributes|
        next unless raw.key?(name)
        value = raw[name]
        raise Discourse::InvalidParameters.new(name) unless value.nil? || value.is_a?(String)
        raise Discourse::InvalidParameters.new(name) if name == "reminder_mode" && value.nil?
        attributes[name] = value
      end
    end

    def self.valid_timezone?(value)
      value.is_a?(String) && TZInfo::Timezone.all_identifiers.include?(value)
    end

    def self.eligible_user?(user)
      user && user.active? && user.approved? && !user.staged? && !user.suspended?
    end

    def self.available_source?(entry, guardian)
      return true unless entry.source_item_id
      source = entry.source_item
      source && !source.cancelled? && source.visible_to?(guardian)
    end

    def self.native_keys(user_id)
      UserApiKey.active.joins(:client, :scopes).where(
        user_id:,
        user_api_key_clients: { client_id: "calendar-subscriptions" },
        user_api_key_scopes: { name: SubscriptionFeed::SCOPE },
      )
    end

    def self.calendar_delivery?(entry)
      subscription_preferred? &&
        entry.reminder_exported_generation == entry.reminder_generation &&
        entry.reminder_exported_policy == policy_version &&
        entry.reminder_exported_key_id.present? &&
        native_keys(entry.user_id).where(id: entry.reminder_exported_key_id).exists?
    end

    def self.delivery_for(entry, guardian)
      return unless enabled? && entry.reminder_at &&
        available_source?(entry, guardian) && eligible_user?(guardian.user)
      return entry.reminder_delivery if entry.reminder_processed_at
      calendar_delivery?(entry) ? "calendar" : "in_app"
    end

    def self.exportable?(entry, guardian, now: Time.current)
      subscription_preferred? && entry.reminder_at && entry.reminder_at > now &&
        !entry.reminder_processed_at && eligible_user?(guardian.user) &&
        available_source?(entry, guardian)
    end

    # Only called after a complete ICS response has been built and rendered with
    # native user-API authentication. Export itself has no database side effects.
    def self.acknowledge_exports(user:, key:, snapshots:, policy_version:)
      return unless subscription_preferred? && self.policy_version == policy_version
      return unless native_keys(user.id).where(id: key.id).exists?

      exports = snapshots.index_by { |snapshot| snapshot[:id] }
      Entry.where(id: exports.keys, user_id: user.id).find_each(batch_size: 100) do |entry|
        snapshot = exports.fetch(entry.id)
        entry.with_lock do
          next unless subscription_preferred? && self.policy_version == policy_version
          next unless entry.reminder_generation == snapshot[:generation] &&
            entry.reminder_at == snapshot[:at] && !entry.reminder_processed_at
          next unless exportable?(entry, user.guardian)
          entry.update_columns(
            reminder_exported_generation: snapshot[:generation],
            reminder_exported_key_id: key.id,
            reminder_exported_policy: policy_version,
          )
        end
      end
    end

    def self.process!(entry, now:)
      entry.with_lock do
        return unless due?(entry, now:)
        channel = nil
        if deliverable?(entry, now:)
          channel = calendar_delivery?(entry) ? "calendar" : "in_app"
          if channel == "in_app"
            Notification.create!(
              user_id: entry.user_id,
              notification_type: Notification.types[:custom],
              data: {
                message: "isbf_calendar.reminder",
                entry_id: entry.id,
                topic_title: entry.title,
              }.to_json,
              skip_send_email: true,
            )
          end
        end
        # Both outcomes, including calendar-only routing, are committed once.
        entry.update_columns(reminder_processed_at: now, reminder_delivery: channel)
      end
    end

    def self.due?(entry, now:)
      entry.reminder_at && !entry.reminder_processed_at && entry.reminder_at <= now
    end

    def self.deliverable?(entry, now:)
      return false unless enabled? && due?(entry, now:)
      return false if entry.reminder_at < now - CATCHUP
      return false if entry.reminder_configured_at && entry.reminder_at <= entry.reminder_configured_at
      changed_at = policy_changed_at
      return false if changed_at && entry.reminder_at < changed_at
      return false unless eligible_user?(entry.user) && available_source?(entry, entry.user.guardian)
      return entry.starts_at > now unless entry.all_day?
      now.in_time_zone(entry.reminder_timezone).to_date ==
        entry.reminder_at.in_time_zone(entry.reminder_timezone).to_date
    end
  end
end
