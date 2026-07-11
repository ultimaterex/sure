class Provider::Gemini < Provider
  include LlmConcept

  # Errors from this provider surface as Provider::Gemini::Error.
  class Error < Provider::Error
    attr_reader :error_type

    def initialize(message, error_type = :unknown, details: nil)
      super(message, details: details)
      @error_type = error_type
    end
  end

  DEFAULT_MODEL_PREFIXES = %w[gemini models/gemini].freeze
  DEFAULT_MODEL = "gemini-2.5-flash"

  def self.effective_model
    configured = ENV["GEMINI_MODEL"].presence || Setting.gemini_model
    configured.presence || DEFAULT_MODEL
  end

  def self.configured?
    ENV["GEMINI_ACCESS_TOKEN"].present? ||
      ENV["GEMINI_API_KEY"].present? ||
      Setting.gemini_access_token.present?
  end

  def initialize(access_token, base_url: nil, model: nil)
    @base_url = base_url.presence
    @client = Provider::Gemini::Client.new(
      access_token: access_token,
      base_url: @base_url,
      timeout: ENV.fetch("GEMINI_REQUEST_TIMEOUT", 120).to_i
    )

    if custom_endpoint? && model.blank?
      raise Error, "Model is required when using a custom Gemini-compatible endpoint"
    end

    @default_model = model.presence || DEFAULT_MODEL
  end

  def supports_model?(model)
    return true if custom_endpoint?

    DEFAULT_MODEL_PREFIXES.any? { |prefix| model.to_s.start_with?(prefix) }
  end

  def provider_name
    custom_endpoint? ? "Custom Gemini-compatible (#{@base_url})" : "Gemini"
  end

  def supported_models_description
    if custom_endpoint?
      "configured model: #{@default_model}"
    else
      "models starting with: #{DEFAULT_MODEL_PREFIXES.join(', ')}"
    end
  end

  def custom_endpoint?
    @base_url.present?
  end

  # Gemini natively accepts PDFs as inlineData parts.
  def supports_pdf_processing?(model: @default_model)
    true
  end

  # --- Auxiliary LLM features (native structured output / inline PDF) --------
  def auto_categorize(transactions: [], user_categories: [], model: "", family: nil, json_mode: nil)
    with_provider_response do
      raise Error.new("Too many transactions to auto-categorize. Max is 25 per request.", :bad_request) if transactions.size > 25
      raise Error.new("No categories available for auto-categorization", :bad_request) if user_categories.blank?

      resolved = effective_model(model)
      processor = Provider::Gemini::AutoCategorizer.new(client, model: resolved, transactions: transactions, user_categories: user_categories)
      result = processor.auto_categorize
      record_llm_usage(family: family, model: resolved, operation: "auto_categorize", usage: processor.last_usage)
      result
    end
  end

  def auto_detect_merchants(transactions: [], user_merchants: [], model: "", family: nil, json_mode: nil)
    with_provider_response do
      raise Error.new("Too many transactions to auto-detect merchants. Max is 25 per request.", :bad_request) if transactions.size > 25

      resolved = effective_model(model)
      processor = Provider::Gemini::AutoMerchantDetector.new(client, model: resolved, transactions: transactions, user_merchants: user_merchants)
      result = processor.auto_detect_merchants
      record_llm_usage(family: family, model: resolved, operation: "auto_detect_merchants", usage: processor.last_usage)
      result
    end
  end

  def enhance_provider_merchants(merchants: [], model: "", family: nil, json_mode: nil)
    with_provider_response do
      raise Error.new("Too many merchants to enhance. Max is 25 per request.", :bad_request) if merchants.size > 25

      resolved = effective_model(model)
      processor = Provider::Gemini::ProviderMerchantEnhancer.new(client, model: resolved, merchants: merchants)
      result = processor.enhance_merchants
      record_llm_usage(family: family, model: resolved, operation: "enhance_provider_merchants", usage: processor.last_usage)
      result
    end
  end

  def process_pdf(pdf_content:, model: "", family: nil)
    with_provider_response do
      resolved = effective_model(model)
      processor = Provider::Gemini::PdfProcessor.new(client, model: resolved, pdf_content: pdf_content)
      result = processor.process
      record_llm_usage(family: family, model: resolved, operation: "process_pdf", usage: processor.last_usage)
      result
    end
  end

  def extract_bank_statement(pdf_content:, model: "", family: nil)
    with_provider_response do
      resolved = effective_model(model)
      processor = Provider::Gemini::BankStatementExtractor.new(client: client, model: resolved, pdf_content: pdf_content)
      result = processor.extract
      record_llm_usage(family: family, model: resolved, operation: "extract_bank_statement", usage: processor.last_usage)
      result
    end
  end

  # --- Chat ------------------------------------------------------------------
  def chat_response(
    prompt,
    model:,
    instructions: nil,
    functions: [],
    function_results: [],
    messages: nil,
    conversation_history: [],
    streamer: nil,
    previous_response_id: nil,
    session_id: nil,
    user_identifier: nil,
    family: nil
  )
    with_provider_response do
      config = Provider::Gemini::ChatConfig.new(
        prompt: prompt,
        instructions: instructions,
        functions: functions,
        function_results: function_results,
        conversation_history: conversation_history,
        default_max_tokens: default_max_tokens
      )

      resolved = effective_model(model)

      # Cache the stable system instruction + tools and reference them, cutting
      # per-request input tokens. Best-effort: nil when unavailable → inline.
      cached_content = context_cache.fetch(
        model: resolved,
        system_instruction: config.system_instruction,
        tools: config.tools
      )
      request = config.build_request(model: model, cached_content: cached_content)

      begin
        parsed, usage =
          if streamer.present? && streaming_enabled?
            stream_chat_response(streamer: streamer, model: resolved, body: request[:body])
          else
            sync_chat_response(streamer: streamer, model: resolved, body: request[:body])
          end

        record_llm_usage(family: family, model: model, operation: "chat", usage: usage)
        parsed
      rescue => e
        record_llm_usage(family: family, model: model, operation: "chat", error: e)
        raise
      end
    end
  end

  private
    attr_reader :client

    def context_cache
      @context_cache ||= Provider::Gemini::ContextCache.new(client)
    end

    def default_max_tokens
      ENV.fetch("GEMINI_MAX_TOKENS", 4096).to_i
    end

    # SSE streaming (token-by-token chat). Precedence: GEMINI_STREAMING env wins
    # (and locks the UI toggle); otherwise the Setting toggle, default on. Set to
    # false to fall back to the sync path if the wire format ever misbehaves.
    def streaming_enabled?
      self.class.flag_enabled?("GEMINI_STREAMING", Setting.gemini_streaming)
    end

    def self.flag_enabled?(env_key, setting_value)
      env = ENV[env_key]
      return ActiveModel::Type::Boolean.new.cast(env) if env.present?

      ActiveModel::Type::Boolean.new.cast(setting_value)
    end

    # generateContent is synchronous. When a streamer is supplied we replay the
    # finished result through it (output text, then the response), matching how
    # the OpenAI generic path drives the assistant.
    def sync_chat_response(streamer:, model:, body:)
      raw = client.generate_content(model: model, body: body)
      parsed = Provider::Gemini::ChatParser.new(raw).parsed
      usage = Provider::Gemini::Usage.from_metadata(raw["usageMetadata"])

      if streamer.present?
        parsed.messages.each do |message|
          next if message.output_text.blank?

          streamer.call(Provider::LlmConcept::ChatStreamChunk.new(type: "output_text", data: message.output_text, usage: nil))
        end
        streamer.call(Provider::LlmConcept::ChatStreamChunk.new(type: "response", data: parsed, usage: usage))
      end

      [ parsed, usage ]
    end

    # True SSE streaming via streamGenerateContent. Emits text deltas as they
    # arrive, accumulates text + functionCall parts, then emits the assembled
    # final response so the caller gets the same shape as the sync path.
    def stream_chat_response(streamer:, model:, body:)
      text = +""
      function_parts = []
      usage = {}
      response_id = nil
      model_version = nil

      client.stream_generate_content(model: model, body: body) do |chunk|
        response_id ||= chunk["responseId"]
        model_version ||= chunk["modelVersion"]

        chunk_function_parts = []
        Array(chunk.dig("candidates", 0, "content", "parts")).each do |part|
          if part["text"].present?
            text << part["text"]
            if streamer.present?
              streamer.call(Provider::LlmConcept::ChatStreamChunk.new(type: "output_text", data: part["text"], usage: nil))
            end
          elsif part["functionCall"]
            chunk_function_parts << part
          end
        end
        # Streaming chunks carry the latest assembled functionCall state, not
        # additive deltas — keep the most recent snapshot.
        function_parts = chunk_function_parts if chunk_function_parts.any?

        usage = Provider::Gemini::Usage.from_metadata(chunk["usageMetadata"]) if chunk["usageMetadata"].present?
      end

      final_parts = []
      final_parts << { "text" => text } unless text.empty?
      final_parts.concat(function_parts)

      parsed = Provider::Gemini::ChatParser.new(
        "responseId" => response_id,
        "modelVersion" => model_version,
        "candidates" => [ { "content" => { "parts" => final_parts } } ]
      ).parsed

      if streamer.present?
        # Match sync_chat_response: the responder only listens for output_text
        # chunks, so text that arrives only in the final assembled response (common
        # after tool calls) must still be emitted here.
        emit_remaining_streamed_text(streamer, text, parsed)
        streamer.call(Provider::LlmConcept::ChatStreamChunk.new(type: "response", data: parsed, usage: usage))
      end

      [ parsed, usage ]
    end

    def emit_remaining_streamed_text(streamer, streamed_text, parsed)
      assembled = parsed.messages.filter_map(&:output_text).join
      return if assembled.blank?

      remaining =
        if streamed_text.present? && assembled.start_with?(streamed_text)
          assembled[streamed_text.length..]
        else
          assembled
        end
      return if remaining.blank?

      streamer.call(Provider::LlmConcept::ChatStreamChunk.new(type: "output_text", data: remaining, usage: nil))
    end

    # Preserve the response body (captured in Error#details) through the
    # with_provider_response transformer so failed requests remain diagnosable.
    def default_error_transformer(error)
      return error if error.is_a?(Error)

      super
    end

    def record_llm_usage(family:, model:, operation:, usage: nil, error: nil)
      return unless family

      # Normalize the resource-name form ("models/gemini-…") to the bare id so it
      # matches the pricing table and groups cleanly in the cost ledger.
      model = model.to_s.delete_prefix("models/")

      if error.present?
        provider_response_body = error.respond_to?(:details) ? error.details : nil
        if provider_response_body.present?
          Rails.logger.error("Gemini rejected request for model #{model}. Provider response body: #{provider_response_body}")
        end

        family.llm_usages.create!(
          provider: "google",
          model: model,
          operation: operation,
          prompt_tokens: 0,
          completion_tokens: 0,
          total_tokens: 0,
          estimated_cost: nil,
          metadata: {
            error: safe_error_message(error),
            provider_response_body: provider_response_body
          }.compact
        )
        return
      end

      return unless usage

      prompt_tokens = usage["input_tokens"] || 0
      completion_tokens = usage["output_tokens"] || 0
      total_tokens = usage["total_tokens"] || (prompt_tokens + completion_tokens)

      estimated_cost = LlmUsage.calculate_cost(
        model: model,
        prompt_tokens: prompt_tokens,
        completion_tokens: completion_tokens,
        cache_read_tokens: usage["cache_read_input_tokens"].to_i
      )

      family.llm_usages.create!(
        provider: "google",
        model: model,
        operation: operation,
        prompt_tokens: prompt_tokens,
        completion_tokens: completion_tokens,
        total_tokens: total_tokens,
        cache_read_tokens: usage["cache_read_input_tokens"],
        estimated_cost: estimated_cost,
        metadata: {}
      )
    rescue => e
      Rails.logger.error("Failed to record Gemini LLM usage: #{e.message}")
    end

    def safe_error_message(error)
      error&.message
    rescue => e
      "(message unavailable: #{e.class})"
    end

    def effective_model(model)
      model.presence || @default_model
    end
end
