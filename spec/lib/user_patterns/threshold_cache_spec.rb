# frozen_string_literal: true

require 'rails_helper'
require 'user_patterns/threshold_cache'

RSpec.describe UserPatterns::ThresholdCache do
  subject(:cache) { described_class.new }

  after { cache.shutdown }

  def create_events(model_type:, endpoint:, per_minute:)
    base = Time.utc(2026, 1, 1, 12, 0, 0)
    per_minute.times do |i|
      UserPatterns::RequestEvent.create!(
        model_type: model_type,
        endpoint: endpoint,
        anonymous_session_id: "s#{i}",
        recorded_at: base + i.seconds,
        created_at: base
      )
    end
  end

  describe '#refresh!' do
    it 'loads limits from stats with multiplier applied' do
      create_events(model_type: 'User', endpoint: 'GET /test', per_minute: 4)
      UserPatterns.configuration.threshold_multiplier = 2.0

      cache.refresh!
      limits = cache.limits_for('User', 'GET /test')

      expect(limits[:per_minute]).to eq(8) # 4 * 2.0
    end

    it 'uses ceil to avoid fractional limits' do
      create_events(model_type: 'User', endpoint: 'GET /test', per_minute: 3)
      UserPatterns.configuration.threshold_multiplier = 1.5

      cache.refresh!
      limits = cache.limits_for('User', 'GET /test')

      expect(limits[:per_minute]).to eq(5) # ceil(3 * 1.5) = 5
    end
  end

  describe '#limits_for' do
    it 'returns nil for unknown endpoints' do
      expect(cache.limits_for('User', 'GET /unknown')).to be_nil
    end

    it 'returns limits for known endpoints' do
      create_events(model_type: 'User', endpoint: 'GET /test', per_minute: 2)
      cache.refresh!

      expect(cache.limits_for('User', 'GET /test')).to be_a(Hash)
    end
  end

  describe '#known_endpoint?' do
    it 'returns false for unknown endpoints' do
      expect(cache.known_endpoint?('User', 'GET /nope')).to be false
    end

    it 'returns true after refresh with data' do
      create_events(model_type: 'User', endpoint: 'GET /test', per_minute: 1)
      cache.refresh!

      expect(cache.known_endpoint?('User', 'GET /test')).to be true
    end
  end

  describe '#all_limits' do
    it 'returns a copy of the limits hash' do
      create_events(model_type: 'User', endpoint: 'GET /a', per_minute: 1)
      create_events(model_type: 'Admin', endpoint: 'GET /b', per_minute: 2)
      cache.refresh!

      all = cache.all_limits
      expect(all.keys).to contain_exactly(['User', 'GET /a'], ['Admin', 'GET /b'])
    end
  end

  describe '#safe_refresh error handling' do
    it 'logs an error when StatsCalculator raises' do
      allow(UserPatterns::StatsCalculator).to receive(:compute_all).and_raise(StandardError, 'db gone')
      allow(Rails.logger).to receive(:error)

      cache.send(:safe_refresh)

      expect(Rails.logger).to have_received(:error).with(/Threshold refresh error: db gone/).at_least(:once)
    end

    it 'does not raise when Rails.logger is nil' do
      allow(UserPatterns::StatsCalculator).to receive(:compute_all).and_raise(StandardError, 'db gone')
      allow(Rails).to receive(:logger).and_return(nil)

      expect { cache.send(:safe_refresh) }.not_to raise_error
    end
  end

  describe '#shutdown' do
    it 'stops the refresh timer' do
      cache.shutdown
      expect(cache.instance_variable_get(:@timer)).to be_shutdown
    end

    it 'handles nil timer gracefully' do
      cache.instance_variable_set(:@timer, nil)
      expect { cache.shutdown }.not_to raise_error
    end
  end
end
