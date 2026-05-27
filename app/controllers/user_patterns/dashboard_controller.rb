# frozen_string_literal: true

require 'user_patterns/session_catalog'
require 'user_patterns/session_timeline'
require 'user_patterns/stats_calculator'

module UserPatterns
  class DashboardController < ActionController::Base
    before_action :authenticate_dashboard!
    before_action :load_session_context, only: %i[sessions session]
    helper_method :session_list_params
    layout false

    def index
      UserPatterns.buffer.flush
      load_stats
      apply_sort!
    end

    def violations
      @violations = Violation
                    .recent(params[:days]&.to_i || 7)
                    .order(occurred_at: :desc)
      @violations = @violations.where(model_type: params[:model_type]) if params[:model_type].present?
    end

    def sessions
      UserPatterns.buffer.flush
      @sessions = SessionCatalog.list(
        model_type: @selected_model,
        endpoint: params[:endpoint],
        page: params[:page]
      )
      @endpoint_filter = params[:endpoint].presence
    end

    def session
      UserPatterns.buffer.flush
      return head(:not_found) unless SessionCatalog.valid_session_id?(params[:id])

      @summary = SessionCatalog.find_summary(params[:id], model_type: @selected_model)
      return head(:not_found) unless @summary

      load_session_detail
    end

    def stylesheet
      css_path = UserPatterns::Engine.root.join('app', 'assets', 'stylesheets', 'user_patterns', 'dashboard.css')
      expires_in 1.hour, public: true
      render plain: css_path.read, content_type: 'text/css'
    end

    private

    def load_stats
      @stats = UserPatterns::StatsCalculator.compute_all
      @model_types = @stats.map { |s| s[:model_type] }.uniq.sort
      @selected_model = params[:model_type].presence || @model_types.first
      @filtered_stats = @stats.select { |s| s[:model_type] == @selected_model }
      @alert_mode = UserPatterns.configuration.alert_mode?
      @threshold_limits = load_threshold_limits
    end

    def load_threshold_limits
      return {} unless @alert_mode && UserPatterns.threshold_cache

      UserPatterns.threshold_cache.all_limits
    end

    def authenticate_dashboard!
      instance_exec(&UserPatterns.configuration.dashboard_auth)
    end

    def apply_sort!
      sort_key = params[:sort]&.to_sym
      return unless sort_key && @filtered_stats.first&.key?(sort_key)

      @filtered_stats.sort_by! { |s| s[sort_key] || 0 }
      @filtered_stats.reverse! unless params[:dir] == 'asc'
    end

    def load_session_context
      @stats = UserPatterns::StatsCalculator.compute_all
      @model_types = @stats.map { |s| s[:model_type] }.uniq.sort
      @model_types = RequestEvent.distinct.pluck(:model_type).sort if @model_types.empty?
      @selected_model = params[:model_type].presence || @model_types.first
      @alert_mode = UserPatterns.configuration.alert_mode?
    end

    def session_list_params
      {
        model_type: @selected_model,
        endpoint: params[:endpoint].presence
      }.compact
    end

    def load_session_detail
      @neighbors = SessionCatalog.neighbors(
        params[:id],
        model_type: @selected_model,
        endpoint: params[:endpoint]
      )
      events = RequestEvent
               .where(anonymous_session_id: params[:id], model_type: @summary.model_type)
               .order(:recorded_at)
      @timeline = SessionTimeline.condense(events)
      @endpoint_filter = params[:endpoint].presence
    end
  end
end
