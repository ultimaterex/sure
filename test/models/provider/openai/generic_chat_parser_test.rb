require "test_helper"

class Provider::Openai::GenericChatParserTest < ActiveSupport::TestCase
  test "captures Gemini's thought signature from a tool_call" do
    raw = {
      "id" => "resp_1",
      "model" => "models/gemini-3.1-flash-lite",
      "choices" => [ {
        "message" => {
          "content" => nil,
          "tool_calls" => [ {
            "id" => "call_1",
            "function" => { "name" => "get_transactions", "arguments" => "{}" },
            "extra_content" => { "google" => { "thought_signature" => "SIG_ABC" } }
          } ]
        }
      } ]
    }

    parsed = Provider::Openai::GenericChatParser.new(raw).parsed
    request = parsed.function_requests.first

    assert_equal "get_transactions", request.function_name
    assert_equal "SIG_ABC", request.thought_signature
  end

  test "thought signature is nil when the provider omits it" do
    raw = {
      "id" => "resp_1",
      "model" => "gpt-4.1",
      "choices" => [ {
        "message" => {
          "tool_calls" => [ {
            "id" => "call_1",
            "function" => { "name" => "get_transactions", "arguments" => "{}" }
          } ]
        }
      } ]
    }

    request = Provider::Openai::GenericChatParser.new(raw).parsed.function_requests.first

    assert_nil request.thought_signature
  end
end
