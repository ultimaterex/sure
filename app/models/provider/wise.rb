# frozen_string_literal: true

# Read-only client for the Wise (wise.com) Platform API.
#
# A Wise *profile* (personal and/or business) holds one *balance account* per
# currency. Transactions come from per-balance "balance statements".
#
# Scope: token-only auth. Balance-statement endpoints are SCA-protected for
# UK/EEA profiles (Wise returns 403 with an `x-2fa-approval` header + JOSE
# request-signing challenge); that is out of scope and surfaced as a clear error.
class Provider::Wise
  include HTTParty

  DEFAULT_BASE_URL = "https://api.wise.com"

  headers "User-Agent" => "Sure Finance Wise Client"
  default_options.merge!(verify: true, ssl_verify_mode: OpenSSL::SSL::VERIFY_PEER, timeout: 120)

  class Error < StandardError
    attr_reader :error_type

    def initialize(message, error_type = :unknown)
      super(message)
      @error_type = error_type
    end
  end

  class ConfigurationError < Error; end
  class AuthenticationError < Error; end

  attr_reader :api_token

  def initialize(api_token:, base_url: nil)
    @api_token = api_token
    @base_url = base_url.presence || DEFAULT_BASE_URL
    validate_configuration!
  end

  # GET /v2/profiles -> [ { id, type: "personal"|"business", ... }, ... ]
  def get_profiles
    with_retries("get_profiles") do
      response = self.class.get("#{@base_url}/v2/profiles", headers: auth_headers)
      handle_response(response)
    end
  end

  # GET /v4/profiles/{profileId}/balances?types=STANDARD
  # -> [ { id, currency, amount: { value, currency }, type, ... }, ... ]
  def get_balances(profile_id, types: "STANDARD")
    with_retries("get_balances") do
      response = self.class.get(
        "#{@base_url}/v4/profiles/#{ERB::Util.url_encode(profile_id.to_s)}/balances",
        headers: auth_headers,
        query: { types: types }
      )
      handle_response(response)
    end
  end

  # GET /v1/profiles/{profileId}/balance-statements/{balanceId}/statement.json
  # -> { transactions: [ { type, date, amount: { value, currency }, referenceNumber, details, runningBalance }, ... ] }
  def get_balance_statement(profile_id:, balance_id:, currency:, start_date:, end_date: Date.current)
    with_retries("get_balance_statement") do
      response = self.class.get(
        "#{@base_url}/v1/profiles/#{ERB::Util.url_encode(profile_id.to_s)}" \
        "/balance-statements/#{ERB::Util.url_encode(balance_id.to_s)}/statement.json",
        headers: auth_headers,
        query: {
          currency: currency,
          intervalStart: format_interval_start(start_date),
          intervalEnd: format_interval_end(end_date),
          type: "COMPACT"
        }
      )
      handle_response(response)
    end
  end

  private

    RETRYABLE_ERRORS = [
      SocketError, Net::OpenTimeout, Net::ReadTimeout,
      Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::ETIMEDOUT, EOFError
    ].freeze

    MAX_RETRIES = 3
    INITIAL_RETRY_DELAY = 2 # seconds

    def validate_configuration!
      raise ConfigurationError, "Api token is required" if @api_token.blank?
    end

    def format_interval_start(date)
      date.to_date.beginning_of_day.utc.iso8601(3)
    end

    def format_interval_end(date)
      date.to_date.end_of_day.utc.iso8601(3)
    end

    def with_retries(operation_name, max_retries: MAX_RETRIES)
      retries = 0

      begin
        yield
      rescue *RETRYABLE_ERRORS => e
        retries += 1

        if retries <= max_retries
          delay = calculate_retry_delay(retries)
          Rails.logger.warn(
            "Wise API: #{operation_name} failed (attempt #{retries}/#{max_retries}): " \
            "#{e.class}: #{e.message}. Retrying in #{delay}s..."
          )
          sleep(delay)
          retry
        else
          Rails.logger.error(
            "Wise API: #{operation_name} failed after #{max_retries} retries: " \
            "#{e.class}: #{e.message}"
          )
          raise Error.new("Network error after #{max_retries} retries: #{e.message}", :network_error)
        end
      end
    end

    def calculate_retry_delay(retry_count)
      base_delay = INITIAL_RETRY_DELAY * (2 ** (retry_count - 1))
      jitter = base_delay * rand * 0.25
      [ base_delay + jitter, 30 ].min
    end

    def auth_headers
      {
        "Authorization" => "Bearer #{@api_token}",
        "Content-Type" => "application/json",
        "Accept" => "application/json"
      }
    end

    def handle_response(response)
      case response.code
      when 200, 201
        JSON.parse(response.body, symbolize_names: true)
      when 400
        Rails.logger.error "Wise API: Bad request - #{response.body}"
        raise Error.new("Bad request: #{response.body}", :bad_request)
      when 401
        raise AuthenticationError.new("Invalid Wise API token", :unauthorized)
      when 403
        # Wise signals Strong Customer Authentication with this header on the
        # balance-statement endpoint. SCA/request-signing is out of scope.
        if response.headers["x-2fa-approval"].present?
          raise AuthenticationError.new(
            "This Wise profile requires Strong Customer Authentication (SCA), " \
            "which this integration does not support yet.",
            :sca_required
          )
        end
        raise AuthenticationError.new("Access forbidden - check your API token permissions", :access_forbidden)
      when 404
        raise Error.new("Resource not found", :not_found)
      when 429
        raise Error.new("Rate limit exceeded. Please try again later.", :rate_limited)
      when 500..599
        raise Error.new("Wise server error (#{response.code}). Please try again later.", :server_error)
      else
        Rails.logger.error "Wise API: Unexpected response - Code: #{response.code}, Body: #{response.body}"
        raise Error.new("Unexpected error: #{response.code} - #{response.body}", :unknown)
      end
    end
end
