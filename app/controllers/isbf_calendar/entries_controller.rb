# frozen_string_literal: true

require "time"

module IsbfCalendar
  class EntriesController < BaseController
    before_action :ensure_logged_in

    def index
      from = parse_time(params.require(:from))
      to = parse_time(params.require(:to))
      raise Discourse::InvalidParameters if to <= from || to > from + 62.days

      entries = personal_entries.where("starts_at < ? AND ends_at > ?", to, from).order(:starts_at, :id)
      render json: { entries: entries.map { |entry| serialize(entry) } }
    end

    def create
      entry = IsbfCalendar::Entry.new(entry_attributes.merge(user: current_user))
      entry.save!
      render json: { entry: serialize(entry) }, status: :created
    end

    def update
      entry = owned_entry
      entry.update!(entry_attributes)
      render json: { entry: serialize(entry) }
    end

    def destroy
      owned_entry.destroy!
      render json: success_json
    end

    private

    def owned_entry
      personal_entries.find(params[:id])
    end

    def personal_entries
      IsbfCalendar::Entry.where(user_id: current_user.id)
    end

    def entry_attributes
      data = params.require(:entry).permit(:title, :starts_at, :ends_at, :all_day, :note)
      {
        title: data[:title]&.strip,
        starts_at: parse_time(data[:starts_at]),
        ends_at: parse_time(data[:ends_at]),
        all_day: ActiveModel::Type::Boolean.new.cast(data[:all_day]),
        note: data[:note]&.strip,
      }
    end

    def parse_time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      raise Discourse::InvalidParameters
    end

    def serialize(entry)
      {
        id: entry.id,
        title: entry.title,
        starts_at: entry.starts_at.iso8601,
        ends_at: entry.ends_at.iso8601,
        all_day: entry.all_day,
        note: entry.note,
      }
    end
  end
end
