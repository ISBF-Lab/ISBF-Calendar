# frozen_string_literal: true

module IsbfCalendar
  class AddOfficialEntry
    include Service::Base

    params do
      attribute :id, :integer
      attribute :revision, :integer
      attribute :reminder_mode, :string
      attribute :reminder_timezone, :string
      validates :id,
                :revision,
                numericality: {
                  only_integer: true,
                  greater_than: 0
                }
    end

    transaction do
      model :item
      policy :can_add
      policy :current_revision
      step :add_entry
    end

    private

    def fetch_item(params:)
      OfficialItem.includes(topic: :first_post).lock.find_by(id: params.id)
    end

    def can_add(item:, guardian:)
      guardian.user && !item.cancelled? && item.visible_to?(guardian)
    end

    def current_revision(item:, params:)
      item.revision == params.revision
    end

    def add_entry(item:, guardian:, params:)
      entry =
        Entry.find_or_initialize_by(
          user_id: guardian.user.id,
          source_item_id: item.id
        )
      context[:created] = entry.new_record?
      if entry.new_record?
        entry.assign_attributes(
          item.snapshot.merge(
            accepted_revision: item.revision,
            notified_revision: item.revision
          )
        )
        entry.reminder_mode = params.reminder_mode unless params.reminder_mode.nil?
        entry.reminder_timezone = params.reminder_timezone unless params.reminder_timezone.nil?
        entry.save!
      end
      context[:entry] = entry
    end
  end
end
