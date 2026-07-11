require "test_helper"

class Provider::GeminiTest < ActiveSupport::TestCase
  def stub_client(raw)
    fake = mock
    fake.stubs(:generate_content).returns(raw)
    Provider::Gemini::Client.stubs(:new).returns(fake)
    fake
  end

  test "parses a text chat response" do
    stub_client(
      "responseId" => "resp_1",
      "modelVersion" => "gemini-2.5-flash",
      "candidates" => [ { "content" => { "role" => "model", "parts" => [ { "text" => "Hello!" } ] }, "finishReason" => "STOP" } ],
      "usageMetadata" => { "promptTokenCount" => 10, "candidatesTokenCount" => 3, "totalTokenCount" => 13 }
    )

    provider = Provider::Gemini.new("test-key")
    response = provider.chat_response("hi", model: "gemini-2.5-flash")

    assert response.success?
    assert_equal 1, response.data.messages.size
    assert_equal "Hello!", response.data.messages.first.output_text
    assert_empty response.data.function_requests
  end

  test "captures a function call with its thought signature" do
    stub_client(
      "responseId" => "resp_2",
      "candidates" => [ {
        "content" => { "parts" => [ {
          "functionCall" => { "name" => "get_transactions", "args" => { "q" => "utilities" } },
          "thoughtSignature" => "SIG_A"
        } ] }
      } ],
      "usageMetadata" => {}
    )

    provider = Provider::Gemini.new("test-key")
    response = provider.chat_response(
      "hi",
      model: "gemini-2.5-flash",
      functions: [ { name: "get_transactions", description: "d", params_schema: { type: "object" } } ]
    )

    request = response.data.function_requests.first
    assert_equal "get_transactions", request.function_name
    assert_equal "SIG_A", request.thought_signature
    assert_equal({ "q" => "utilities" }, JSON.parse(request.function_args))
  end

  test "streamer receives output text then the final response" do
    stub_client(
      "responseId" => "resp_3",
      "candidates" => [ { "content" => { "parts" => [ { "text" => "Answer" } ] } } ],
      "usageMetadata" => { "promptTokenCount" => 1, "candidatesTokenCount" => 1, "totalTokenCount" => 2 }
    )

    chunks = []
    provider = Provider::Gemini.new("test-key")
    provider.chat_response("hi", model: "gemini-2.5-flash", streamer: ->(c) { chunks << c })

    assert_equal %w[output_text response], chunks.map(&:type)
    assert_equal "Answer", chunks.first.data
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
end
