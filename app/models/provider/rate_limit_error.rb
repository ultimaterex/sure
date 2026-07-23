# frozen_string_literal: true

# Raised when an LLM provider returns HTTP 429 so background jobs can retry with
# backoff (via ApplicationJob#retry_on) instead of silently dropping the work.
# Provider errors expose an `error_type`; a 429 sets it to :rate_limited.
class Provider::RateLimitError < StandardError
  def self.rate_limited?(error)
    error.respond_to?(:error_type) && error.error_type == :rate_limited
  end
end
