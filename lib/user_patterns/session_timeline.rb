# frozen_string_literal: true

module UserPatterns
  # Collapses a session's request events into scannable timeline segments.
  class SessionTimeline
    POLLING_MIN_COUNT = 3
    POLLING_MIN_DURATION = 8.0
    POLLING_INTERVAL_RANGE = 0.5..60.0
    POLLING_MAX_INTERVAL_CV = 0.65
    BURST_MAX_DURATION = 3.0
    BURST_MIN_COUNT = 5

    Segment = Struct.new(
      :kind,
      :endpoint,
      :hits,
      :started_at,
      :ended_at,
      :duration_seconds,
      :annotation,
      keyword_init: true
    )

    def self.condense(events)
      new(events).condense
    end

    def initialize(events)
      @events = Array(events).sort_by(&:recorded_at)
    end

    def condense
      return [] if @events.empty?

      build_groups.map(&:to_segment)
    end

    private

    def build_groups
      groups = []
      @events.each do |event|
        if groups.last&.endpoint == event.endpoint
          groups.last << event
        else
          groups << EventGroup.new(event)
        end
      end
      groups
    end

    class EventGroup
      attr_reader :endpoint, :events

      def initialize(event)
        @endpoint = event.endpoint
        @events = [event]
      end

      def <<(event)
        @events << event
      end

      def count
        @events.size
      end

      def started_at
        @events.first.recorded_at
      end

      def ended_at
        @events.last.recorded_at
      end

      def duration_seconds
        span = (ended_at.to_time - started_at.to_time).to_f
        span.negative? ? 0.0 : span
      end

      def to_segment
        SessionTimeline::Segment.new(
          kind: classify,
          endpoint: endpoint,
          hits: count,
          started_at: started_at,
          ended_at: ended_at,
          duration_seconds: duration_seconds,
          annotation: annotation_for(classify)
        )
      end

      private

      def classify
        return :single if count == 1
        return :burst if duration_seconds <= SessionTimeline::BURST_MAX_DURATION &&
                         count >= SessionTimeline::BURST_MIN_COUNT
        return :polling if polling?

        :repeated
      end

      def polling?
        return false if count < SessionTimeline::POLLING_MIN_COUNT
        return false if duration_seconds < SessionTimeline::POLLING_MIN_DURATION

        intervals = request_intervals
        average = intervals.sum / intervals.size.to_f
        return false unless SessionTimeline::POLLING_INTERVAL_RANGE.cover?(average)

        coefficient_of_variation(intervals, average) <= SessionTimeline::POLLING_MAX_INTERVAL_CV
      end

      def request_intervals
        @events.each_cons(2).map do |prev, curr|
          (curr.recorded_at.to_time - prev.recorded_at.to_time).to_f
        end
      end

      def coefficient_of_variation(values, mean)
        return 0.0 if mean.zero? || values.size < 2

        variance = values.sum { |v| (v - mean)**2 } / values.size.to_f
        Math.sqrt(variance) / mean
      end

      def annotation_for(kind)
        case kind
        when :single then nil
        when :burst then 'burst'
        when :polling then polling_annotation
        when :repeated then "×#{count}"
        end
      end

      def polling_annotation
        intervals = request_intervals
        average = intervals.sum / intervals.size.to_f
        "polling · ~#{DurationFormatter.compact(average)} interval · ×#{count}"
      end
    end
  end

  # Formats durations for timeline annotations.
  module DurationFormatter
    module_function

    def compact(seconds)
      seconds = seconds.to_f
      return '0s' if seconds < 1

      if seconds < 60
        "#{seconds.round}s"
      elsif seconds < 3600
        minutes = (seconds / 60).floor
        remainder = (seconds % 60).round
        remainder.zero? ? "#{minutes}m" : "#{minutes}m #{remainder}s"
      else
        hours = (seconds / 3600).floor
        minutes = ((seconds % 3600) / 60).floor
        minutes.zero? ? "#{hours}h" : "#{hours}h #{minutes}m"
      end
    end

    def range(started_at, ended_at)
      compact((ended_at.to_time - started_at.to_time).to_f)
    end
  end
end
