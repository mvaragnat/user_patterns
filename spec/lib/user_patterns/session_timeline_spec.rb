# frozen_string_literal: true

require 'rails_helper'
require 'user_patterns/session_timeline'

RSpec.describe UserPatterns::SessionTimeline do
  def build_event(endpoint:, at:)
    UserPatterns::RequestEvent.new(
      endpoint: endpoint,
      recorded_at: at,
      model_type: 'User',
      anonymous_session_id: 'abc123def456789a',
      created_at: at
    )
  end

  let(:base_time) { Time.zone.parse('2026-05-27 10:00:00') }

  describe '.condense' do
    it 'returns an empty array for no events' do
      expect(described_class.condense([])).to eq([])
    end

    it 'keeps a single request as one segment' do
      events = [build_event(endpoint: 'GET /dashboard', at: base_time)]

      segments = described_class.condense(events)

      expect(segments.size).to eq(1)
      expect(segments.first).to have_attributes(
        kind: :single,
        endpoint: 'GET /dashboard',
        hits: 1,
        annotation: nil
      )
    end

    it 'groups consecutive identical endpoints' do
      events = [
        build_event(endpoint: 'GET /items', at: base_time),
        build_event(endpoint: 'GET /items', at: base_time + 2.seconds),
        build_event(endpoint: 'POST /cart', at: base_time + 5.seconds)
      ]

      segments = described_class.condense(events)

      expect(segments.map(&:kind)).to eq(%i[repeated single])
      expect(segments.first).to have_attributes(hits: 2, annotation: '×2')
    end

    it 'labels rapid repeated calls as a burst' do
      events = Array.new(6) do |i|
        build_event(endpoint: 'GET /firehose', at: base_time + (i * 0.3).seconds)
      end

      segments = described_class.condense(events)

      expect(segments.first).to have_attributes(kind: :burst, hits: 6, annotation: 'burst')
    end

    it 'labels steady-interval repetition as polling' do
      events = Array.new(5) do |i|
        build_event(endpoint: 'GET /status', at: base_time + (i * 3).seconds)
      end

      segments = described_class.condense(events)

      expect(segments.first.kind).to eq(:polling)
      expect(segments.first.annotation).to include('polling')
      expect(segments.first.annotation).to include('×5')
    end

    it 'treats irregular repetition as repeated, not polling' do
      events = [
        build_event(endpoint: 'GET /status', at: base_time),
        build_event(endpoint: 'GET /status', at: base_time + 3.seconds),
        build_event(endpoint: 'GET /status', at: base_time + 20.seconds),
        build_event(endpoint: 'GET /status', at: base_time + 23.seconds)
      ]

      expect(described_class.condense(events).first.kind).to eq(:repeated)
    end

    it 'treats zero-duration spans as repeated when below burst thresholds' do
      events = [
        build_event(endpoint: 'GET /twice', at: base_time),
        build_event(endpoint: 'GET /twice', at: base_time)
      ]

      expect(described_class.condense(events).first).to have_attributes(kind: :repeated, hits: 2)
    end

    it 'does not label slow-spaced triplets as polling' do
      events = Array.new(3) do |i|
        build_event(endpoint: 'GET /status', at: base_time + (i * 90).seconds)
      end

      expect(described_class.condense(events).first.kind).to eq(:repeated)
    end

    it 'does not treat pairs as polling' do
      events = [
        build_event(endpoint: 'GET /status', at: base_time),
        build_event(endpoint: 'GET /status', at: base_time + 15.seconds)
      ]

      expect(described_class.condense(events).first.kind).to eq(:repeated)
    end

    it 'does not label short triplets as polling when duration is under the threshold' do
      events = [
        build_event(endpoint: 'GET /status', at: base_time),
        build_event(endpoint: 'GET /status', at: base_time + 2.seconds),
        build_event(endpoint: 'GET /status', at: base_time + 4.seconds)
      ]

      expect(described_class.condense(events).first.kind).to eq(:repeated)
    end

    it 'clamps negative durations to zero' do
      group = described_class::EventGroup.new(build_event(endpoint: 'GET /x', at: base_time + 5.seconds))
      group << build_event(endpoint: 'GET /x', at: base_time)

      expect(group.duration_seconds).to eq(0.0)
    end

    it 'returns zero coefficient of variation when the mean is zero' do
      group = described_class::EventGroup.new(build_event(endpoint: 'GET /x', at: base_time))

      expect(group.send(:coefficient_of_variation, [1.0, 2.0], 0.0)).to eq(0.0)
    end

    it 'returns no annotation for unknown segment kinds' do
      group = described_class::EventGroup.new(build_event(endpoint: 'GET /x', at: base_time))

      expect(group.send(:annotation_for, :unknown)).to be_nil
    end
  end
end

RSpec.describe UserPatterns::DurationFormatter do
  describe '.compact' do
    it 'formats sub-second, minute, and hour durations' do
      expect(described_class.compact(0.5)).to eq('0s')
      expect(described_class.compact(12)).to eq('12s')
      expect(described_class.compact(90)).to eq('1m 30s')
      expect(described_class.compact(120)).to eq('2m')
      expect(described_class.compact(3600)).to eq('1h')
      expect(described_class.compact(3900)).to eq('1h 5m')
    end
  end

  describe '.range' do
    it 'formats the span between two timestamps' do
      start = Time.zone.parse('2026-05-27 10:00:00')
      finish = start + 45.seconds

      expect(described_class.range(start, finish)).to eq('45s')
    end
  end
end
