# frozen_string_literal: true

module UserPatterns
  class Engine < ::Rails::Engine
    isolate_namespace UserPatterns

    initializer 'user_patterns.controller_tracking' do
      ActiveSupport.on_load(:action_controller_base) do
        require 'user_patterns/controller_tracking'
        include UserPatterns::ControllerTracking
      end

      ActiveSupport.on_load(:action_controller_api) do
        require 'user_patterns/controller_tracking'
        include UserPatterns::ControllerTracking
      end
    end

    # :nocov:start
    initializer 'user_patterns.default_salt' do
      config.after_initialize do
        UserPatterns.configuration.anonymous_salt ||=
          Rails.application.secret_key_base&.byteslice(0, 32) || SecureRandom.hex(16)
      end
    end

    initializer 'user_patterns.alert_mode' do
      config.after_initialize do
        UserPatterns.start_alert_mode! if UserPatterns.configuration.alert_mode?
      end
    end

    initializer 'user_patterns.cleanup_task' do
      config.after_initialize do
        load File.expand_path('../tasks/user_patterns.rake', __dir__) if defined?(Rake)
      end
    end
    # :nocov:end
  end
end
