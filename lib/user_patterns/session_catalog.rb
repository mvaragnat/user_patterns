# frozen_string_literal: true

module UserPatterns
  SessionSummary = Struct.new(
    :anonymous_session_id,
    :model_type,
    :request_count,
    :first_at,
    :last_at,
    keyword_init: true
  )

  # Lists anonymized sessions and resolves prev/next navigation in activity order.
  class SessionCatalog
    PER_PAGE = 50
    SESSION_ID_PATTERN = /\A[0-9a-f]{16}\z/

    def self.list(model_type: nil, endpoint: nil, page: 1, per_page: PER_PAGE)
      new(model_type: model_type, endpoint: endpoint).list(page: page, per_page: per_page)
    end

    def self.find_summary(anonymous_session_id, model_type: nil)
      new(model_type: model_type).find_summary(anonymous_session_id)
    end

    def self.neighbors(anonymous_session_id, model_type: nil, endpoint: nil)
      new(model_type: model_type, endpoint: endpoint).neighbors(anonymous_session_id)
    end

    def self.valid_session_id?(id)
      id.to_s.match?(SESSION_ID_PATTERN)
    end

    def initialize(model_type: nil, endpoint: nil)
      @model_type = model_type.presence
      @endpoint = endpoint.presence
    end

    def list(page: 1, per_page: PER_PAGE)
      page = [page.to_i, 1].max
      offset = (page - 1) * per_page

      rows = scoped
             .group(:model_type, :anonymous_session_id)
             .order(Arel.sql('MAX(recorded_at) DESC'))
             .offset(offset)
             .limit(per_page)
             .pluck(
               :anonymous_session_id,
               :model_type,
               Arel.sql('COUNT(*)'),
               Arel.sql('MIN(recorded_at)'),
               Arel.sql('MAX(recorded_at)')
             )

      rows.map { |row| build_summary(*row) }
    end

    def find_summary(anonymous_session_id)
      row = scoped
            .where(anonymous_session_id: anonymous_session_id)
            .group(:model_type, :anonymous_session_id)
            .pick(
              :anonymous_session_id,
              :model_type,
              Arel.sql('COUNT(*)'),
              Arel.sql('MIN(recorded_at)'),
              Arel.sql('MAX(recorded_at)')
            )
      return nil unless row

      build_summary(*row)
    end

    def neighbors(anonymous_session_id)
      summary = find_summary(anonymous_session_id)
      return { newer: nil, older: nil } unless summary

      newer_row = neighbor_row(summary.last_at, direction: :newer)
      older_row = neighbor_row(summary.last_at, direction: :older)

      {
        newer: newer_row && build_summary(*newer_row),
        older: older_row && build_summary(*older_row)
      }
    end

    private

    def scoped
      scope = RequestEvent.all
      scope = scope.where(model_type: @model_type) if @model_type
      scope = scope.where(endpoint: @endpoint) if @endpoint
      scope
    end

    def neighbor_row(last_at, direction:)
      comparator = direction == :newer ? '>' : '<'
      order = direction == :newer ? 'ASC' : 'DESC'

      scoped
        .group(:model_type, :anonymous_session_id)
        .having("MAX(recorded_at) #{comparator} ?", last_at)
        .order(Arel.sql("MAX(recorded_at) #{order}"))
        .limit(1)
        .pluck(
          :anonymous_session_id,
          :model_type,
          Arel.sql('COUNT(*)'),
          Arel.sql('MIN(recorded_at)'),
          Arel.sql('MAX(recorded_at)')
        )
        .first
    end

    def build_summary(anonymous_session_id, model_type, request_count, first_at, last_at)
      SessionSummary.new(
        anonymous_session_id: anonymous_session_id,
        model_type: model_type,
        request_count: request_count,
        first_at: coerce_time(first_at),
        last_at: coerce_time(last_at)
      )
    end

    def coerce_time(value)
      return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)

      Time.zone.parse(value.to_s)
    end
  end
end
