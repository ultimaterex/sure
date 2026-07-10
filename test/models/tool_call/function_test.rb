require "test_helper"

class ToolCall::FunctionTest < ActiveSupport::TestCase
  # Exercises the multi-turn history path: a persisted tool_call replayed into a
  # later request must carry the thought signature back (via to_tool_call), or
  # Gemini rejects the follow-up.
  test "to_tool_call echoes extra_content when a thought signature is present" do
    call = ToolCall::Function.new(
      provider_id: "call_1",
      provider_call_id: "call_1",
      function_name: "get_transactions",
      function_arguments: {},
      function_result: [],
      thought_signature: "SIG_ABC"
    )

    assert_equal(
      { google: { thought_signature: "SIG_ABC" } },
      call.to_tool_call[:extra_content]
    )
    assert_equal "SIG_ABC", call.to_result[:thought_signature]
  end

  test "to_tool_call omits extra_content when there is no thought signature" do
    call = ToolCall::Function.new(
      provider_id: "call_1",
      provider_call_id: "call_1",
      function_name: "get_transactions",
      function_arguments: {},
      function_result: []
    )

    assert_not call.to_tool_call.key?(:extra_content)
  end

  test "from_function_request carries the thought signature through" do
    request = Provider::LlmConcept::ChatFunctionRequest.new(
      id: "call_1",
      call_id: "call_1",
      function_name: "get_transactions",
      function_args: "{}",
      thought_signature: "SIG_ABC"
    )

    call = ToolCall::Function.from_function_request(request, "[]")

    assert_equal "SIG_ABC", call.thought_signature
  end
end
