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
      feed = SubscriptionFeed.new(entries:, guardian: current_user.guardian)
      render plain: feed.to_ical, content_type: "text/calendar; charset=utf-8"

      # Native authentication must actually have selected this key. A browser
      # session download alone cannot establish calendar subscription consumption.
      if is_user_api?
        raw_key = request.get_header(Auth::DefaultCurrentUserProvider::USER_API_KEY) || params[:user_api_key]
        key = Reminders.native_keys(current_user.id).with_key(raw_key).first
        if key
          Reminders.acknowledge_exports(
            user: current_user,
            key:,
            snapshots: feed.reminder_exports,
            policy_version: feed.reminder_policy_version,
          )
        end
      end
    end
  end
end
