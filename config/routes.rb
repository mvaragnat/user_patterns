# frozen_string_literal: true

UserPatterns::Engine.routes.draw do
  get 'stylesheet', to: 'dashboard#stylesheet', as: :stylesheet
  get 'violations', to: 'dashboard#violations', as: :violations
  get 'sessions', to: 'dashboard#sessions', as: :sessions
  get 'sessions/:id', to: 'dashboard#session', as: :session
  root to: 'dashboard#index'
end
