# frozen_string_literal: true

module IsbfCalendar
  class Entry < ActiveRecord::Base
    self.table_name = "isbf_calendar_entries"

    belongs_to :user
    belongs_to :source_item,
               class_name: "IsbfCalendar::OfficialItem",
               optional: true

    validates :title, presence: true, length: { maximum: 120 }
    validates :note, length: { maximum: 2000 }
    validates :location, length: { maximum: 255 }
    validates :starts_at, :ends_at, presence: true
    validates :schedule_kind, inclusion: { in: %w[event deadline] }
    validate :ends_after_start
    before_validation :normalize_reminder
    validate :valid_reminder
    before_save :plan_reminder

    scope :overlapping,
          ->(from, to) do
            where(
              "starts_at < :to AND (ends_at > :from OR (starts_at = ends_at AND starts_at >= :from))",
              from:,
              to:
            )
          end
    scope :pending_updates,
          -> do
            joins(:source_item).where(
              "isbf_calendar_official_items.revision > GREATEST(isbf_calendar_entries.accepted_revision, isbf_calendar_entries.dismissed_revision)"
            )
          end

    def needs_update?
      source_item &&
        source_item.revision > [accepted_revision, dismissed_revision].max
    end

    def effective_location(guardian)
      return location unless location.nil?
      return "" unless source_item && accepted_revision == source_item.revision
      return "" unless source_item.visible_to?(guardian)

      source_item.location.to_s
    end

    private

    def normalize_reminder
      modes = all_day? ? Reminders::ALL_DAY_MODES : Reminders::TIMED_MODES
      if persisted? && will_save_change_to_all_day? && !modes.include?(reminder_mode)
        self.reminder_mode = "none"
      end
      self.reminder_timezone = IsbfCalendar::TIMEZONE if source_item_id && all_day? && reminder_mode != "none"
      self.reminder_timezone = nil if reminder_mode == "none"
    end

    def valid_reminder
      modes = all_day? ? Reminders::ALL_DAY_MODES : Reminders::TIMED_MODES
      errors.add(:reminder_mode, :invalid) unless modes.include?(reminder_mode)
      return if reminder_mode == "none"
      if (all_day? || reminder_timezone.present?) && !Reminders.valid_timezone?(reminder_timezone)
        errors.add(:reminder_timezone, :invalid)
      end
    end

    def plan_reminder
      return unless new_record? ||
        %w[starts_at all_day reminder_mode reminder_timezone].any? { |field| will_save_change_to_attribute?(field) }

      self.reminder_generation += 1
      self.reminder_configured_at = Time.current
      self.reminder_at =
        if Reminders::TIMED_OFFSETS.key?(reminder_mode)
          starts_at - Reminders::TIMED_OFFSETS.fetch(reminder_mode)
        elsif Reminders::ALL_DAY_MODES.include?(reminder_mode) && reminder_mode != "none"
          date_zone = source_item_id ? IsbfCalendar::TIMEZONE : "UTC"
          date = starts_at.in_time_zone(date_zone).to_date
          date -= 1 if reminder_mode == "previous_day_9am"
          Time.find_zone!(reminder_timezone).local(date.year, date.month, date.day, 9)
        end
      self.reminder_processed_at = reminder_at && reminder_at <= reminder_configured_at ? reminder_configured_at : nil
      self.reminder_delivery = nil
      self.reminder_exported_generation = nil
      self.reminder_exported_key_id = nil
      self.reminder_exported_policy = nil
    end

    def ends_after_start
      return if starts_at.blank? || ends_at.blank? || ends_at > starts_at
      return if source_item_id.present? && !all_day && ends_at == starts_at

      errors.add(:ends_at, "must be after the start")
    end
  end
end

# == Schema Information
#
# Table name: isbf_calendar_entries
#
#  id                 :bigint           not null, primary key
#  accepted_revision  :integer          default(0), not null
#  all_day            :boolean          default(FALSE), not null
#  dismissed_revision :integer          default(0), not null
#  ends_at            :datetime         not null
#  note               :text
#  notified_revision  :integer          default(0), not null
#  schedule_kind      :string           default("event"), not null
#  starts_at          :datetime         not null
#  title              :string(120)      not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  source_item_id     :bigint
#  user_id            :bigint           not null
#
# Indexes
#
#  idx_isbf_calendar_entries_source_user          (user_id,source_item_id) UNIQUE WHERE (source_item_id IS NOT NULL)
#  idx_isbf_calendar_user_start                   (user_id,starts_at)
#  index_isbf_calendar_entries_on_source_item_id  (source_item_id)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id) ON DELETE => cascade
#
