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

  # Creates an Interaction (native, stateful chat turn). `body` is the full
  # interactions request hash. Returns the parsed Interaction resource, whose
  # `id` is threaded back as `previous_interaction_id` on follow-up calls.
  def create_interaction(body:)
    response = self.class.post(
      "#{@base_url}/v1beta/interactions",
      headers: headers,
      body: body.to_json,
      timeout: @timeout
    )
    handle_response(response)
  end

  # Streaming generation over SSE. Yields each decoded response chunk. Chunks
  # that aren't model output (e.g. an error body streamed as fragments) are
  # filtered out; a non-200 status is raised after the stream completes.
  def stream_generate_content(model:, body:)
    parser = Provider::Gemini::StreamParser.new

    response = self.class.post(
      "#{@base_url}/v1beta/#{model_path(model)}:streamGenerateContent?alt=sse",
      headers: headers,
      body: body.to_json,
      timeout: @timeout,
      stream_body: true
    ) do |fragment|
      parser.push(fragment) { |chunk| yield chunk if response_chunk?(chunk) }
    end

    unless response.code == 200
      raise Provider::Gemini::Error.new("Gemini streaming request failed (status #{response.code})", :fetch_failed)
    end

    nil
  end

  # Creates a cached-content object holding stable request context (system
  # instruction + tools) and returns its `name` for reuse via `cachedContent`.
  def create_cached_content(model:, system_instruction: nil, tools: nil, ttl_seconds: 3600)
    body = { model: "models/#{model.to_s.delete_prefix('models/')}", ttl: "#{ttl_seconds}s" }
    body[:systemInstruction] = system_instruction if system_instruction.present?
    body[:tools] = tools if tools.present?

    response = self.class.post(
      "#{@base_url}/v1beta/cachedContents",
      headers: headers,
      body: body.to_json,
      timeout: @timeout
    )
    handle_response(response)["name"]
  end

  private

    def response_chunk?(chunk)
      chunk.is_a?(Hash) && (chunk.key?("candidates") || chunk.key?("usageMetadata"))
    end

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
