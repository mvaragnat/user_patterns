# frozen_string_literal: true

require 'rails_helper'
require 'user_patterns/session_catalog'

RSpec.describe UserPatterns::SessionCatalog do
  def create_event(attrs = {})
    UserPatterns::RequestEvent.create!({
      model_type: 'User',
      endpoint: 'GET /mulder_case',
      anonymous_session_id: 'abc123def456789a',
      recorded_at: Time.current,
      created_at: Time.current
    }.merge(attrs))
  end

  describe '.valid_session_id?' do
    it 'accepts 16-character hex ids' do
      expect(described_class.valid_session_id?('abc123def456789a')).to be(true)
    end

    it 'rejects malformed ids' do
      expect(described_class.valid_session_id?('not-a-session')).to be(false)
    end
  end

  describe '.find_summary' do
    it 'returns nil when the session does not exist' do
      expect(described_class.find_summary('0000000000000000', model_type: 'User')).to be_nil
    end
  end

  describe '#coerce_time' do
    it 'returns TimeWithZone values unchanged' do
      timestamp = Time.zone.parse('2026-05-27 10:00:00')

      expect(described_class.new.send(:coerce_time, timestamp)).to eq(timestamp)
    end
  end

  describe '.list' do
    it 'orders sessions by most recent activity first' do
      create_event(
        anonymous_session_id: 'aaaaaaaaaaaaaaaa',
        recorded_at: 2.hours.ago
      )
      create_event(
        anonymous_session_id: 'bbbbbbbbbbbbbbbb',
        recorded_at: 5.minutes.ago
      )

      summaries = described_class.list(model_type: 'User')

      expect(summaries.map(&:anonymous_session_id)).to eq(
        %w[bbbbbbbbbbbbbbbb aaaaaaaaaaaaaaaa]
      )
    end

    it 'filters sessions that hit a specific endpoint' do
      create_event(anonymous_session_id: 'aaaaaaaaaaaaaaaa', endpoint: 'GET /scully_lab')
      create_event(anonymous_session_id: 'bbbbbbbbbbbbbbbb', endpoint: 'GET /other_room')

      summaries = described_class.list(model_type: 'User', endpoint: 'GET /scully_lab')

      expect(summaries.map(&:anonymous_session_id)).to eq(['aaaaaaaaaaaaaaaa'])
    end

    it 'normalizes page numbers below 1' do
      create_event(anonymous_session_id: 'aaaaaaaaaaaaaaaa')

      expect(described_class.list(model_type: 'User', page: 0).size).to eq(1)
    end
  end

  describe '.neighbors' do
    it 'returns empty neighbors for an unknown session' do
      expect(described_class.neighbors('0000000000000000', model_type: 'User')).to eq(
        newer: nil,
        older: nil
      )
    end
    it 'returns newer and older sessions by last activity' do
      create_event(anonymous_session_id: '1111111111111111', recorded_at: 3.hours.ago)
      create_event(anonymous_session_id: '2222222222222222', recorded_at: 2.hours.ago)
      create_event(anonymous_session_id: '3333333333333333', recorded_at: 1.hour.ago)

      neighbors = described_class.neighbors('2222222222222222', model_type: 'User')

      expect(neighbors[:newer].anonymous_session_id).to eq('3333333333333333')
      expect(neighbors[:older].anonymous_session_id).to eq('1111111111111111')
    end
  end
end
