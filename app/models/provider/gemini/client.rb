# frozen_string_literal: true

# Thin HTTP client for Google's native Gemini (Generative Language) REST API.
# Kept separate from Provider::Gemini so request/response plumbing is easy to
# stub in tests.
class Provider::Gemini::Client
  include HTTParty

  DEFAULT_BASE_URL = "https://generativelanguage.googleapis.com"

  def initialize(access_token:, base_url: nil, timeout: 120)
    @access_token = access_token
    @base_url = (base_url.presence || DEFAULT_BASE_URL).to_s.chomp("/")
    @timeout = timeout
  end

  # Non-streaming generation. `body` is the generateContent request hash.
  def generate_content(model:, body:)
    response = self.class.post(
      "#{@base_url}/v1beta/#{model_path(model)}:generateContent",
      headers: headers,
      body: body.to_json,
      timeout: @timeout
    )
    handle_response(response)
  end

  private

    def model_path(model)
      model = model.to_s
      model.start_with?("models/") ? model : "models/#{model}"
    end

    def headers
      # Key travels in a header (never the URL/query) so it can't leak into
      # request logs or error messages.
      {
        "x-goog-api-key" => @access_token,
        "Content-Type" => "application/json",
        "Accept" => "application/json"
      }
    end

    def handle_response(response)
      case response.code
      when 200
        JSON.parse(response.body)
      when 400
        raise error("Bad request to Gemini API: #{response.body}", :bad_request, response)
      when 401, 403
        raise error("Gemini authentication failed — check your API key and its permissions.", :unauthorized, response)
      when 404
        raise error("Gemini model or resource not found: #{response.body}", :not_found, response)
      when 429
        raise error("Gemini rate limit exceeded. Please try again later.", :rate_limited, response)
      when 500..599
        raise error("Gemini server error (#{response.code}). Please try again later.", :server_error, response)
      else
        raise error("Unexpected Gemini response (#{response.code}): #{response.body}", :unknown, response)
      end
    end

    def error(message, type, response)
      Provider::Gemini::Error.new(message, type, details: safe_body(response))
    end

    def safe_body(response)
      body = response.body
      return nil if body.blank?

      body.to_s.truncate(4000)
    rescue StandardError
      nil
    end
end
