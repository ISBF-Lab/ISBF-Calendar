# frozen_string_literal: true

module IsbfCalendar
  class SubscriptionsController < BaseController
    skip_before_action :check_xhr, only: :show, if: -> { request.format.ics? }
    before_action :ensure_logged_in

    def show
      raise Discourse::NotFound unless request.format.ics?

      now = Time.current
      entries =
        Entry
          .where(user_id: current_user.id)
          .overlapping(now - 1.year, now + 2.years)
          .includes(source_item: { topic: :first_post })
          .order(:starts_at, :id)

      response.headers["Cache-Control"] = "private, no-store"
      response.headers["Referrer-Policy"] = "no-referrer"
      render plain: SubscriptionFeed.new(entries:, guardian: current_user.guardian).to_ical,
             content_type: "text/calendar; charset=utf-8"
    end
  end
end
