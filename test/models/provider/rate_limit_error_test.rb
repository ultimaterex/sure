require "test_helper"

class Provider::RateLimitErrorTest < ActiveSupport::TestCase
  test "rate_limited? recognizes a 429 provider error" do
    assert Provider::RateLimitError.rate_limited?(Provider::Gemini::Error.new("slow down", :rate_limited))
  end

  test "rate_limited? is false for other errors" do
    assert_not Provider::RateLimitError.rate_limited?(Provider::Gemini::Error.new("bad", :bad_request))
    assert_not Provider::RateLimitError.rate_limited?(StandardError.new("boom"))
  end

  test "auto-detect merchants re-raises a retryable RateLimitError on 429" do
    family = families(:empty)
    detector = Family::AutoMerchantDetector.new(family, transaction_ids: [ "x" ])

    provider = mock
    provider.stubs(:auto_detect_merchants).returns(
      Provider::Response.new(success?: false, data: nil, error: Provider::Gemini::Error.new("Gemini rate limit exceeded", :rate_limited))
    )

    detector.stubs(:llm_provider).returns(provider)
    detector.stubs(:scope).returns([ OpenStruct.new(id: "x") ])
    detector.stubs(:transactions_input).returns([])
    detector.stubs(:user_merchants_input).returns([])

    assert_raises(Provider::RateLimitError) { detector.auto_detect }
  end

  test "auto-detect merchants swallows non-rate-limit errors (no retry)" do
    family = families(:empty)
    detector = Family::AutoMerchantDetector.new(family, transaction_ids: [ "x" ])

    provider = mock
    provider.stubs(:auto_detect_merchants).returns(
      Provider::Response.new(success?: false, data: nil, error: Provider::Gemini::Error.new("bad request", :bad_request))
    )

    detector.stubs(:llm_provider).returns(provider)
    detector.stubs(:scope).returns([ OpenStruct.new(id: "x") ])
    detector.stubs(:transactions_input).returns([])
    detector.stubs(:user_merchants_input).returns([])

    assert_equal 0, detector.auto_detect
  end
end
