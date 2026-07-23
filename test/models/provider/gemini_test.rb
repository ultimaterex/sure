require "test_helper"

class Provider::GeminiTest < ActiveSupport::TestCase
  # Fake client that records request bodies and replays scripted Interaction
  # resources across successive create_interaction calls.
  class ScriptedInteractionClient
    attr_reader :bodies

    def initialize(*responses)
      @responses = responses
      @bodies = []
    end

    def create_interaction(body:)
      @bodies << body
      @responses[@bodies.size - 1] || @responses.last
    end
  end

  def stub_interactions(*responses)
    client = ScriptedInteractionClient.new(*responses)
    Provider::Gemini::Client.stubs(:new).returns(client)
    client
  end

  def model_output_interaction(id:, text:, usage: { "total_input_tokens" => 1, "total_output_tokens" => 1, "total_tokens" => 2 })
    {
      "id" => id,
      "status" => "completed",
      "steps" => [ { "type" => "model_output", "content" => [ { "type" => "text", "text" => text } ] } ],
      "usage" => usage
    }
  end

  test "parses a text chat response" do
    stub_interactions(
      model_output_interaction(id: "int_1", text: "Hello!",
        usage: { "total_input_tokens" => 10, "total_output_tokens" => 3, "total_tokens" => 13 })
    )

    response = Provider::Gemini.new("test-key").chat_response("hi", model: "gemini-2.5-flash")

    assert response.success?
    assert_equal "int_1", response.data.id
    assert_equal 1, response.data.messages.size
    assert_equal "Hello!", response.data.messages.first.output_text
    assert_empty response.data.function_requests
  end

  test "captures a function call from a function_call step" do
    stub_interactions(
      {
        "id" => "int_2",
        "status" => "requires_action",
        "steps" => [ { "type" => "function_call", "id" => "fc_1", "name" => "get_transactions", "arguments" => { "q" => "utilities" } } ],
        "usage" => {}
      }
    )

    response = Provider::Gemini.new("test-key").chat_response(
      "hi",
      model: "gemini-2.5-flash",
      functions: [ { name: "get_transactions", description: "d", params_schema: { type: "object" } } ]
    )

    request = response.data.function_requests.first
    assert_equal "get_transactions", request.function_name
    assert_equal "fc_1", request.call_id
    assert_equal({ "q" => "utilities" }, JSON.parse(request.function_args))
  end

  test "replays the interaction through the streamer as output_text then response" do
    stub_interactions(model_output_interaction(id: "int_3", text: "Answer"))

    chunks = []
    Provider::Gemini.new("test-key").chat_response("hi", model: "gemini-2.5-flash", streamer: ->(c) { chunks << c })

    assert_equal %w[output_text response], chunks.map(&:type)
    assert_equal "Answer", chunks.first.data
  end

  test "multi-step tool calling threads previous_interaction_id and sends function_result steps" do
    client = stub_interactions(
      {
        "id" => "int_1",
        "status" => "requires_action",
        "steps" => [ { "type" => "function_call", "id" => "fc_1", "name" => "get_transactions", "arguments" => { "q" => "x" } } ],
        "usage" => { "total_input_tokens" => 100, "total_output_tokens" => 25, "total_tokens" => 125 }
      },
      model_output_interaction(id: "int_2", text: "You spent $420.")
    )
    functions = [ { name: "get_transactions", description: "d", params_schema: { type: "object" } } ]
    provider = Provider::Gemini.new("k")

    # First call: no function_results -> history + prompt, and NO previous_interaction_id
    # (the cross-turn id may be stale/expired or from another provider).
    r1 = provider.chat_response("find unusual", model: "gemini-3.1-flash-lite", functions: functions, previous_response_id: "stale_cross_turn")
    assert_equal "int_1", r1.data.id
    assert_equal "fc_1", r1.data.function_requests.first.call_id

    # Follow-up: function_results present -> function_result steps + the fresh previous_interaction_id.
    r2 = provider.chat_response(
      "find unusual",
      model: "gemini-3.1-flash-lite",
      functions: functions,
      function_results: [ { call_id: "fc_1", name: "get_transactions", output: "[]" } ],
      previous_response_id: "int_1"
    )
    assert_equal "You spent $420.", r2.data.messages.first.output_text

    first, second = client.bodies
    assert_not first.key?(:previous_interaction_id), "first call must not chain a (possibly stale) cross-turn id"
    assert_equal "user_input", first[:input].last[:type]
    assert_equal "int_1", second[:previous_interaction_id]
    assert_equal "function_result", second[:input].first[:type]
    assert_equal "fc_1", second[:input].first[:call_id]
  end

  test "supports gemini models and rejects others" do
    provider = Provider::Gemini.new("test-key")
    assert provider.supports_model?("gemini-2.5-flash")
    assert provider.supports_model?("models/gemini-3.1-flash-lite")
    assert_not provider.supports_model?("gpt-4.1")
  end

  test "custom endpoint supports any model but requires an explicit model" do
    provider = Provider::Gemini.new("test-key", base_url: "https://proxy.example.com", model: "custom-model")
    assert provider.supports_model?("anything")

    assert_raises(Provider::Gemini::Error) do
      Provider::Gemini.new("test-key", base_url: "https://proxy.example.com")
    end
  end

  test "native gemini usage is attributed to google for pricing" do
    assert_equal "google", LlmUsage.infer_provider("gemini-2.5-flash")
    assert_equal "google", LlmUsage.infer_provider("models/gemini-3.1-flash-lite")
  end

  # --- ChatConfig ------------------------------------------------------------
  test "build_request maps prompt, instructions and tools" do
    body = Provider::Gemini::ChatConfig.new(
      prompt: "hi",
      instructions: "system",
      functions: [ { name: "f", description: "d", params_schema: { type: "object" } } ]
    ).build_request(model: "gemini-2.5-flash")[:body]

    assert_equal({ parts: [ { text: "system" } ] }, body[:systemInstruction])
    assert_equal [ { role: "user", parts: [ { text: "hi" } ] } ], body[:contents]
    assert_equal "f", body[:tools].first[:functionDeclarations].first[:name]
  end

  test "build_request strips Gemini-unsupported schema keywords from tool parameters" do
    functions = [ {
      name: "search",
      description: "d",
      params_schema: {
        type: "object",
        additionalProperties: false,
        properties: {
          tags: { type: "array", uniqueItems: true, items: { type: "string" } }
        },
        required: [ "tags" ]
      }
    } ]

    body = Provider::Gemini::ChatConfig.new(prompt: "hi", functions: functions).build_request(model: "m")[:body]
    params = body[:tools].first[:functionDeclarations].first[:parameters]

    assert_not params.key?(:additionalProperties)
    assert_not params[:properties][:tags].key?(:uniqueItems)
    assert_equal "string", params[:properties][:tags][:items][:type]
    assert_equal [ "tags" ], params[:required]
  end

  test "build_request replays tool results as model functionCall (with signature) + user functionResponse" do
    body = Provider::Gemini::ChatConfig.new(
      prompt: "hi",
      function_results: [ {
        name: "get_transactions",
        call_id: "c1",
        arguments: '{"q":"x"}',
        output: "[]",
        thought_signature: "SIG_A"
      } ]
    ).build_request(model: "m")[:body]

    model_content = body[:contents].find { |c| c[:role] == "model" }
    call_part = model_content[:parts].first
    assert_equal "get_transactions", call_part[:functionCall][:name]
    assert_equal({ "q" => "x" }, call_part[:functionCall][:args])
    assert_equal "SIG_A", call_part[:thoughtSignature]

    response_content = body[:contents].reverse.find { |c| c[:role] == "user" && c[:parts].first[:functionResponse] }
    assert response_content, "expected a user functionResponse content"
    assert_equal "get_transactions", response_content[:parts].first[:functionResponse][:name]
  end

  # --- Usage -----------------------------------------------------------------
  test "usage maps gemini metadata field names" do
    usage = Provider::Gemini::Usage.from_metadata(
      "promptTokenCount" => 10, "candidatesTokenCount" => 5, "totalTokenCount" => 15,
      "cachedContentTokenCount" => 4, "thoughtsTokenCount" => 2
    )

    assert_equal 10, usage["input_tokens"]
    assert_equal 5, usage["output_tokens"]
    assert_equal 15, usage["total_tokens"]
    assert_equal 4, usage["cache_read_input_tokens"]
  end

  # --- Auxiliary features (structured output / inline PDF) -------------------
  def stub_json_client(payload)
    fake = mock
    fake.stubs(:generate_content).returns(
      "candidates" => [ { "content" => { "parts" => [ { "text" => payload.to_json } ] } } ],
      "usageMetadata" => { "promptTokenCount" => 5, "candidatesTokenCount" => 5, "totalTokenCount" => 10 }
    )
    Provider::Gemini::Client.stubs(:new).returns(fake)
    fake
  end

  test "auto_categorize maps structured output and normalizes null" do
    stub_json_client("categorizations" => [
      { "transaction_id" => "1", "category_name" => "Shopping" },
      { "transaction_id" => "2", "category_name" => "null" }
    ])

    response = Provider::Gemini.new("k").auto_categorize(
      transactions: [ { id: "1", name: "Amazon" }, { id: "2", name: "POS DEBIT" } ],
      user_categories: [ { id: "s", name: "Shopping" } ]
    )

    assert response.success?
    assert_equal "Shopping", response.data.find { |c| c.transaction_id == "1" }.category_name
    assert_nil response.data.find { |c| c.transaction_id == "2" }.category_name
  end

  test "auto_detect_merchants maps structured output" do
    stub_json_client("merchants" => [ { "transaction_id" => "1", "business_name" => "Amazon", "business_url" => "amazon.com" } ])

    response = Provider::Gemini.new("k").auto_detect_merchants(
      transactions: [ { id: "1", name: "amzn 123" } ],
      user_merchants: []
    )

    assert response.success?
    assert_equal "Amazon", response.data.first.business_name
    assert_equal "amazon.com", response.data.first.business_url
  end

  test "enhance_provider_merchants maps structured output" do
    stub_json_client("merchants" => [ { "merchant_id" => "m1", "business_url" => "walmart.com" } ])

    response = Provider::Gemini.new("k").enhance_provider_merchants(merchants: [ { id: "m1", name: "Walmart" } ])

    assert response.success?
    assert_equal "walmart.com", response.data.first.business_url
  end

  test "process_pdf classifies and summarizes" do
    stub_json_client("document_type" => "bank_statement", "summary" => "A statement", "extracted_data" => { "currency" => "USD" })

    response = Provider::Gemini.new("k").process_pdf(pdf_content: "%PDF-1.4 fake")

    assert response.success?
    assert_equal "bank_statement", response.data.document_type
    assert_equal "A statement", response.data.summary
    assert_equal "USD", response.data.extracted_data["currency"]
  end

  test "extract_bank_statement normalizes transactions" do
    stub_json_client(
      "bank_name" => "Test Bank",
      "transactions" => [ { "date" => "2026-01-15", "description" => "Coffee", "amount" => -4.5, "reference" => "REF1" } ]
    )

    response = Provider::Gemini.new("k").extract_bank_statement(pdf_content: "%PDF-1.4 fake")

    assert response.success?
    txn = response.data[:transactions].first
    assert_equal "2026-01-15", txn[:date]
    assert_equal(-4.5, txn[:amount])
    assert_equal "Coffee", txn[:name]
    assert_equal "REF1", txn[:notes]
  end

  test "auto_categorize rejects oversized batches" do
    Provider::Gemini::Client.stubs(:new).returns(mock)
    txns = Array.new(26) { |i| { id: i.to_s, name: "t#{i}" } }

    response = Provider::Gemini.new("k").auto_categorize(transactions: txns, user_categories: [ { id: "s", name: "Shopping" } ])

    assert_not response.success?
    assert_kind_of Provider::Gemini::Error, response.error
  end

  # --- SSE streaming ---------------------------------------------------------
  test "StreamParser splits SSE events and decodes JSON" do
    parser = Provider::Gemini::StreamParser.new
    seen = []
    parser.push("data: {\"a\":1}\n\ndata: {\"b\":2}\n\n") { |json| seen << json }
    assert_equal [ { "a" => 1 }, { "b" => 2 } ], seen
  end

  test "StreamParser buffers partial events across fragments and ignores [DONE]" do
    parser = Provider::Gemini::StreamParser.new
    seen = []
    parser.push("data: {\"x\":") { |json| seen << json }
    assert_empty seen
    parser.push("1}\n\ndata: [DONE]\n\n") { |json| seen << json }
    assert_equal [ { "x" => 1 } ], seen
  end

  # --- Pricing (#1) ----------------------------------------------------------
  test "gemini 3.x models have pricing" do
    assert_not_nil LlmUsage.calculate_cost(model: "gemini-3.1-flash-lite", prompt_tokens: 1000, completion_tokens: 1000)
    assert_not_nil LlmUsage.calculate_cost(model: "gemini-3.1-pro", prompt_tokens: 1000, completion_tokens: 1000)
    # flash-lite must price cheaper than flash (ordering / exact-match sanity)
    lite = LlmUsage.calculate_cost(model: "gemini-3.1-flash-lite", prompt_tokens: 1_000_000, completion_tokens: 0)
    flash = LlmUsage.calculate_cost(model: "gemini-3.1-flash", prompt_tokens: 1_000_000, completion_tokens: 0)
    assert lite < flash
  end

  # --- Context cache (#3) ----------------------------------------------------
  test "context cache is disabled by default" do
    cache = Provider::Gemini::ContextCache.new(mock)
    assert_nil cache.fetch(model: "gemini-2.5-flash", system_instruction: { parts: [ { text: "sys" } ] }, tools: [])
  end

  test "context cache creates and returns a cache name when enabled" do
    with_env_overrides("GEMINI_CONTEXT_CACHE" => "true") do
      client = mock
      client.expects(:create_cached_content).returns("cachedContents/abc")

      cache = Provider::Gemini::ContextCache.new(client)
      name = cache.fetch(
        model: "gemini-2.5-flash",
        system_instruction: { parts: [ { text: "sys-#{SecureRandom.hex}" } ] },
        tools: []
      )
      assert_equal "cachedContents/abc", name
    end
  end

  test "context cache falls back to nil on provider error (never breaks the request)" do
    with_env_overrides("GEMINI_CONTEXT_CACHE" => "true") do
      client = mock
      client.stubs(:create_cached_content).raises(Provider::Gemini::Error.new("cached content too small", :bad_request))

      cache = Provider::Gemini::ContextCache.new(client)
      assert_nil cache.fetch(
        model: "gemini-2.5-flash",
        system_instruction: { parts: [ { text: "sys-#{SecureRandom.hex}" } ] },
        tools: []
      )
    end
  end

  test "build_request references cachedContent and omits system + tools" do
    body = Provider::Gemini::ChatConfig.new(
      prompt: "hi",
      instructions: "sys",
      functions: [ { name: "f", description: "d", params_schema: { type: "object" } } ]
    ).build_request(model: "m", cached_content: "cachedContents/abc")[:body]

    assert_equal "cachedContents/abc", body[:cachedContent]
    assert_not body.key?(:systemInstruction)
    assert_not body.key?(:tools)
    assert body[:contents].present?
  end

  # --- InteractionConfig -----------------------------------------------------
  test "InteractionConfig first call sends history + prompt and no previous_interaction_id" do
    history = [
      OpenStruct.new(role: "user", content: "earlier q"),
      OpenStruct.new(role: "assistant", content: "earlier a")
    ]

    body = Provider::Gemini::InteractionConfig.new(
      prompt: "now",
      instructions: "system",
      conversation_history: history,
      functions: [ { name: "f", description: "d", params_schema: { type: "object" } } ],
      previous_interaction_id: "stale_int"
    ).build_request(model: "gemini-3.1-flash-lite")

    assert_equal "system", body[:system_instruction]
    assert_equal "function", body[:tools].first[:type]
    assert_not body.key?(:previous_interaction_id)
    assert_equal %w[user_input model_output user_input], body[:input].map { |step| step[:type] }
    assert_equal "now", body[:input].last[:content].first[:text]
  end

  test "InteractionConfig follow-up sends function_result steps and chains previous_interaction_id" do
    body = Provider::Gemini::InteractionConfig.new(
      prompt: "now",
      function_results: [ { call_id: "fc_1", name: "get_transactions", output: [ 1, 2 ] } ],
      previous_interaction_id: "int_1"
    ).build_request(model: "m")

    assert_equal "int_1", body[:previous_interaction_id]
    step = body[:input].first
    assert_equal "function_result", step[:type]
    assert_equal "fc_1", step[:call_id]
    assert_equal "get_transactions", step[:name]
    assert_equal "[1,2]", step[:result].first[:text]
  end

  test "InteractionConfig strips Gemini-unsupported schema keywords from tool parameters" do
    functions = [ {
      name: "search",
      description: "d",
      params_schema: {
        type: "object",
        additionalProperties: false,
        properties: { tags: { type: "array", uniqueItems: true, items: { type: "string" } } },
        required: [ "tags" ]
      }
    } ]

    body = Provider::Gemini::InteractionConfig.new(prompt: "hi", functions: functions).build_request(model: "m")
    params = body[:tools].first[:parameters]

    assert_not params.key?(:additionalProperties)
    assert_not params[:properties][:tags].key?(:uniqueItems)
    assert_equal [ "tags" ], params[:required]
  end

  # --- InteractionParser -----------------------------------------------------
  test "InteractionParser extracts model_output text and function_call requests" do
    parsed = Provider::Gemini::InteractionParser.new(
      "id" => "int_9",
      "model" => "gemini-3.1-flash-lite",
      "steps" => [
        { "type" => "thought", "signature" => "sig" },
        { "type" => "function_call", "id" => "fc_1", "name" => "get_accounts", "arguments" => { "limit" => 5 } },
        { "type" => "model_output", "content" => [ { "type" => "text", "text" => "Here " }, { "type" => "text", "text" => "you go." } ] }
      ]
    ).parsed

    assert_equal "int_9", parsed.id
    assert_equal "Here you go.", parsed.messages.first.output_text
    assert_equal "get_accounts", parsed.function_requests.first.function_name
    assert_equal "fc_1", parsed.function_requests.first.call_id
    assert_equal({ "limit" => 5 }, JSON.parse(parsed.function_requests.first.function_args))
  end

  # --- Usage (Interactions) --------------------------------------------------
  test "usage maps interaction usage field names" do
    usage = Provider::Gemini::Usage.from_interaction(
      "total_input_tokens" => 100, "total_output_tokens" => 25, "total_tokens" => 125,
      "total_cached_tokens" => 40, "total_thought_tokens" => 12
    )

    assert_equal 100, usage["input_tokens"]
    assert_equal 25, usage["output_tokens"]
    assert_equal 125, usage["total_tokens"]
    assert_equal 40, usage["cache_read_input_tokens"]
  end

  # --- Bank statement extractor ----------------------------------------------
  test "parse_amount preserves unknown/invalid amounts as nil instead of 0.0" do
    extractor = Provider::Gemini::BankStatementExtractor.new(client: mock, model: "m", pdf_content: "x")

    # Blank / non-numeric must not become a fabricated zero-value transaction
    assert_nil extractor.send(:parse_amount, nil)
    assert_nil extractor.send(:parse_amount, "")
    assert_nil extractor.send(:parse_amount, "   ")
    assert_nil extractor.send(:parse_amount, "N/A")
    assert_nil extractor.send(:parse_amount, "-")

    # Real values still parse, including currency-formatted strings
    assert_equal(-45.99, extractor.send(:parse_amount, "-$45.99"))
    assert_equal 1234.5, extractor.send(:parse_amount, "1,234.50")
    assert_equal 0.0, extractor.send(:parse_amount, 0)
    assert_equal 12.0, extractor.send(:parse_amount, "12")
  end
end
