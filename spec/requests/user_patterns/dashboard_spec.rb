# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Dashboard', type: :request do
  def create_event(attrs = {})
    UserPatterns::RequestEvent.create!({
      model_type: 'User',
      endpoint: 'GET /test',
      anonymous_session_id: 'session_a',
      recorded_at: Time.current,
      created_at: Time.current
    }.merge(attrs))
  end

  def create_violation(attrs = {})
    UserPatterns::Violation.create!({
      model_type: 'User',
      endpoint: 'GET /api/test',
      period: 'minute',
      count: 9,
      limit: 8,
      user_identifier: 'abc123def456789a',
      occurred_at: Time.current,
      created_at: Time.current
    }.merge(attrs))
  end

  describe 'secure by default' do
    it 'returns 403 when no env vars and no custom auth are set' do
      UserPatterns.configuration.dashboard_auth = nil
      get '/user_patterns'

      expect(response).to have_http_status(:forbidden)
      expect(response.body).to include('USER_PATTERNS_DASHBOARD_USER')
    end

    context 'with env vars set' do
      around do |example|
        ENV['USER_PATTERNS_DASHBOARD_USER'] = 'testadmin'
        ENV['USER_PATTERNS_DASHBOARD_PASSWORD'] = 'testsecret'
        UserPatterns.reset!
        UserPatterns.configuration.anonymous_salt = 'test_salt_32chars_for_hmac_key!!'
        UserPatterns.configuration.flush_interval = 99_999
        example.run
      ensure
        ENV.delete('USER_PATTERNS_DASHBOARD_USER')
        ENV.delete('USER_PATTERNS_DASHBOARD_PASSWORD')
      end

      it 'requires HTTP Basic Auth' do
        get '/user_patterns'
        expect(response).to have_http_status(:unauthorized)
      end

      it 'allows access with correct credentials' do
        credentials = ActionController::HttpAuthentication::Basic.encode_credentials('testadmin', 'testsecret')
        get '/user_patterns', headers: { 'HTTP_AUTHORIZATION' => credentials }
        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe 'GET /user_patterns' do
    before { UserPatterns.configuration.dashboard_auth = -> {} }

    it 'renders the empty state when no data exists' do
      get '/user_patterns'

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('UserPatterns')
      expect(response.body).to include('No data collected yet')
    end

    it 'displays endpoint stats when events exist' do
      create_event(endpoint: 'GET /api/items')

      get '/user_patterns'

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('GET /api/items')
    end

    it 'filters stats by model type' do
      create_event(model_type: 'User',  endpoint: 'GET /users')
      create_event(model_type: 'Admin', endpoint: 'GET /admin')

      get '/user_patterns', params: { model_type: 'Admin' }

      expect(response.body).to include('GET /admin')
      expect(response.body).not_to include('GET /users')
    end

    it 'sorts by requested column descending by default' do
      2.times { create_event(endpoint: 'GET /popular') }
      create_event(endpoint: 'GET /rare')

      get '/user_patterns', params: { sort: 'total_requests' }

      body = response.body
      expect(body.index('GET /popular')).to be < body.index('GET /rare')
    end

    it 'sorts ascending when dir=asc' do
      2.times { create_event(endpoint: 'GET /popular') }
      create_event(endpoint: 'GET /rare')

      get '/user_patterns', params: { sort: 'total_requests', dir: 'asc' }

      body = response.body
      expect(body.index('GET /rare')).to be < body.index('GET /popular')
    end

    it 'shows the event count in the footer' do
      3.times { create_event }

      get '/user_patterns'

      expect(response.body).to include('3 events in store')
    end

    it 'shows the mode badge' do
      get '/user_patterns'
      expect(response.body).to include('Collection Mode')
    end

    it 'ignores a sort parameter when there are no stats' do
      get '/user_patterns', params: { sort: 'total_requests' }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('No data collected yet')
    end

    context 'when in alert mode with threshold data' do
      before do
        UserPatterns.configuration.mode = :alert
        create_event(endpoint: 'GET /api/items')

        require 'user_patterns/threshold_cache'
        cache = instance_double(UserPatterns::ThresholdCache)
        allow(cache).to receive(:all_limits).and_return(
          { ['User', 'GET /api/items'] => { per_minute: 8, per_hour: 45, per_day: 150 } }
        )
        allow(UserPatterns).to receive(:threshold_cache).and_return(cache)
      end

      it 'shows threshold limit columns' do
        get '/user_patterns'

        expect(response.body).to include('Alert Mode')
        expect(response.body).to include('Limit / Min')
      end
    end
  end

  describe 'GET /user_patterns/violations' do
    before { UserPatterns.configuration.dashboard_auth = -> {} }

    it 'renders the violations page' do
      get '/user_patterns/violations'

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Violations')
    end

    it 'displays recorded violations' do
      create_violation(endpoint: 'GET /api/danger')

      get '/user_patterns/violations'

      expect(response.body).to include('GET /api/danger')
      expect(response.body).to include('minute')
    end

    it 'shows only recent violations by default' do
      create_violation(occurred_at: 10.days.ago)
      create_violation(endpoint: 'GET /recent', occurred_at: 1.day.ago)

      get '/user_patterns/violations'

      expect(response.body).to include('GET /recent')
      expect(response.body).not_to include('GET /api/test')
    end

    it 'filters violations by model type' do
      create_violation(model_type: 'User', endpoint: 'GET /user_action')
      create_violation(model_type: 'Admin', endpoint: 'GET /admin_action')

      get '/user_patterns/violations', params: { model_type: 'Admin' }

      expect(response.body).to include('GET /admin_action')
      expect(response.body).not_to include('GET /user_action')
    end

    it 'accepts a custom days parameter' do
      create_violation(occurred_at: 20.days.ago, endpoint: 'GET /old')
      create_violation(occurred_at: 1.day.ago, endpoint: 'GET /recent')

      get '/user_patterns/violations', params: { days: 30 }

      expect(response.body).to include('GET /old')
      expect(response.body).to include('GET /recent')
    end
  end

  describe 'GET /user_patterns/sessions' do
    before { UserPatterns.configuration.dashboard_auth = -> {} }

    it 'renders the sessions list' do
      get '/user_patterns/sessions'

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Sessions')
    end

    it 'lists anonymized sessions' do
      create_event(anonymous_session_id: 'abc123def456789a', recorded_at: 1.hour.ago)

      get '/user_patterns/sessions'

      expect(response.body).to include('abc123de')
      expect(response.body).to include('View timeline')
    end

    it 'filters sessions by endpoint' do
      create_event(anonymous_session_id: 'abc123def456789a', endpoint: 'GET /tracked')
      create_event(anonymous_session_id: 'fedcba9876543210', endpoint: 'GET /ignored')

      get '/user_patterns/sessions', params: { endpoint: 'GET /tracked' }

      expect(response.body).to include('abc123de')
      expect(response.body).not_to include('fedcba98')
    end
  end

  describe 'GET /user_patterns/sessions/:id' do
    before { UserPatterns.configuration.dashboard_auth = -> {} }

    it 'renders a condensed session timeline' do
      base = Time.zone.parse('2026-05-27 12:00:00')
      5.times do |i|
        create_event(
          anonymous_session_id: 'abc123def456789a',
          endpoint: 'GET /poll',
          recorded_at: base + (i * 3).seconds
        )
      end
      create_event(
        anonymous_session_id: 'abc123def456789a',
        endpoint: 'GET /done',
        recorded_at: base + 20.seconds
      )

      get '/user_patterns/sessions/abc123def456789a'

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Condensed timeline')
      expect(response.body).to include('polling')
      expect(response.body).to include('GET /done')
    end

    it 'provides prev and next navigation between sessions' do
      create_event(anonymous_session_id: '1111111111111111', recorded_at: 2.hours.ago)
      create_event(anonymous_session_id: '2222222222222222', recorded_at: 1.hour.ago)
      create_event(anonymous_session_id: '3333333333333333', recorded_at: 10.minutes.ago)

      get '/user_patterns/sessions/2222222222222222'

      expect(response.body).to include('Newer session')
      expect(response.body).to include('Older session')
      expect(response.body).to include('/user_patterns/sessions/3333333333333333')
      expect(response.body).to include('/user_patterns/sessions/1111111111111111')
    end

    it 'returns 404 for malformed session ids' do
      get '/user_patterns/sessions/not-valid'

      expect(response).to have_http_status(:not_found)
    end

    it 'returns 404 when the session id is valid but unknown' do
      get '/user_patterns/sessions/0000000000000000'

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'GET /user_patterns/stylesheet' do
    before { UserPatterns.configuration.dashboard_auth = -> {} }

    it 'serves CSS with the correct content type' do
      get '/user_patterns/stylesheet'

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include('text/css')
      expect(response.body).to include('font-family')
    end
  end

  describe 'dashboard authentication' do
    before do
      UserPatterns.configuration.dashboard_auth = lambda {
        head :unauthorized unless request.headers['X-Test-Auth'] == 'secret'
      }
    end

    it 'blocks unauthenticated access' do
      get '/user_patterns'
      expect(response).to have_http_status(:unauthorized)
    end

    it 'allows authenticated access' do
      get '/user_patterns', headers: { 'X-Test-Auth' => 'secret' }
      expect(response).to have_http_status(:ok)
    end
  end
end
