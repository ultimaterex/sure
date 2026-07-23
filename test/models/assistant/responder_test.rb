require "test_helper"

class Assistant::ResponderTest < ActiveSupport::TestCase
  Concept = Provider::LlmConcept

  # A minimal LLM double that plays a scripted sequence of responses. Each step
  # is either { text: "..." } (a final answer) or { tools: [names...] } (tool
  # calls). It invokes the streamer with the text, mirroring the real providers.
  class ScriptedLlm
    attr_reader :calls

    def initialize(script)
      @script = script
      @calls = 0
    end

    def chat_response(_prompt, streamer: nil, **_kwargs)
      step = @script.fetch(@calls)
      @calls += 1

      requests = Array(step[:tools]).each_with_index.map do |name, i|
        id = "#{name}-#{@calls}-#{i}"
        Concept::ChatFunctionRequest.new(id: id, call_id: id, function_name: name, function_args: "{}")
      end

      messages = step[:text] ? [ Concept::ChatMessage.new(id: "m#{@calls}", output_text: step[:text]) ] : []

      if streamer && step[:text]
        streamer.call(Concept::ChatStreamChunk.new(type: "output_text", data: step[:text], usage: nil))
      end

      data = Concept::ChatResponse.new(id: "resp#{@calls}", model: "m", messages: messages, function_requests: requests)
      Provider::Response.new(success?: true, data: data, error: nil)
    end
  end

  class ScriptedToolCaller
    def function_definitions
      []
    end

    def fulfill_requests(requests)
      requests.map do |r|
        ToolCall::Function.new(
          provider_id: r.id,
          provider_call_id: r.call_id,
          function_name: r.function_name,
          function_arguments: r.function_args,
          function_result: "ok"
        )
      end
    end
  end

  def build_responder(llm)
    Assistant::Responder.new(
      message: messages(:chat1_user),
      instructions: "system",
      function_tool_caller: ScriptedToolCaller.new,
      llm: llm
    )
  end

  def run_and_capture(llm)
    responder = build_responder(llm)
    texts = []
    responses = []
    responder.on(:output_text) { |t| texts << t }
    responder.on(:response) { |d| responses << d }
    responder.respond
    [ texts, responses ]
  end

  test "streams a plain text answer in a single round" do
    llm = ScriptedLlm.new([ { text: "Hello there" } ])

    texts, responses = run_and_capture(llm)

    assert_equal 1, llm.calls
    assert_equal [ "Hello there" ], texts
    assert_nil responses.last[:function_tool_calls], "final response should finalize without tool calls"
  end

  test "runs multiple sequential tool rounds and then answers" do
    llm = ScriptedLlm.new([
      { tools: [ "get_transactions" ] },
      { tools: [ "get_accounts" ] },
      { text: "You spent $100 on utilities" }
    ])

    texts, = run_and_capture(llm)

    assert_equal 3, llm.calls, "expected 2 tool rounds + 1 answering call"
    assert_equal [ "You spent $100 on utilities" ], texts
  end

  test "stops at the round cap and never leaves a blank, pending turn" do
    # Model keeps calling tools and never answers -> must hit the cap and still
    # emit text so the chat watchdog never reports 'didn't respond'.
    script = Array.new(Assistant::Responder::MAX_TOOL_CALL_ROUNDS + 3) { { tools: [ "loop" ] } }
    llm = ScriptedLlm.new(script)

    texts, = run_and_capture(llm)

    assert_equal Assistant::Responder::MAX_TOOL_CALL_ROUNDS + 1, llm.calls,
      "one initial call plus MAX_TOOL_CALL_ROUNDS follow-ups"
    assert_equal 1, texts.size
    assert_match(/wasn't able to finish/i, texts.first)
  end
end
