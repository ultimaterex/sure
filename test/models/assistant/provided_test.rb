require "test_helper"

class Assistant::ProvidedTest < ActiveSupport::TestCase
  class Harness
    include Assistant::Provided
  end

  test "prefers the user-selected provider among those that support a model" do
    # A custom OpenAI-compatible provider claims every model; the native Gemini
    # provider claims gemini models. When the user picked Gemini, it must win.
    custom_openai = Provider::Openai.new("k", uri_base: "https://proxy.example/openai", model: "models/gemini-3.1-flash-lite")
    gemini = Provider::Gemini.new("k")

    registry = mock
    registry.stubs(:providers).returns([ custom_openai, gemini ])

    harness = Harness.new
    harness.stubs(:registry).returns(registry)

    Setting.stubs(:llm_provider).returns("gemini")
    assert_instance_of Provider::Gemini, harness.get_model_provider("models/gemini-3.1-flash-lite")

    Setting.stubs(:llm_provider).returns("openai")
    assert_instance_of Provider::Openai, harness.get_model_provider("models/gemini-3.1-flash-lite")
  end

  test "falls back to the first supporting provider when the selection doesn't match" do
    gemini = Provider::Gemini.new("k")
    registry = mock
    registry.stubs(:providers).returns([ gemini ])

    harness = Harness.new
    harness.stubs(:registry).returns(registry)

    Setting.stubs(:llm_provider).returns("anthropic") # not among supporters
    assert_instance_of Provider::Gemini, harness.get_model_provider("gemini-2.5-flash")
  end

  test "Chat.default_model resolves the Gemini model when Gemini is selected" do
    Setting.stubs(:llm_provider).returns("gemini")
    Provider::Gemini.stubs(:configured?).returns(true)
    Provider::Gemini.stubs(:effective_model).returns("gemini-2.5-flash")

    assert_equal "gemini-2.5-flash", Chat.default_model
  end
end
