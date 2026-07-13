require "test_helper"

class Rule::ActionExecutorTest < ActiveSupport::TestCase
  setup do
    @rule = rules(:one)
    @executor = Rule::ActionExecutor::AutoDetectMerchants.new(@rule)
  end

  test "bulk_enqueue_wait staggers batches for self-hosters to stay under LLM rate limits" do
    @rule.family.stubs(:self_hoster?).returns(true)

    with_env_overrides("AI_ENRICHMENT_JOB_SPACING_SECONDS" => "5") do
      assert_nil @executor.send(:bulk_enqueue_wait, 0), "first batch fires immediately"
      assert_equal 5.seconds, @executor.send(:bulk_enqueue_wait, 1)
      assert_equal 15.seconds, @executor.send(:bulk_enqueue_wait, 3)
    end
  end

  test "bulk_enqueue_wait does not stagger managed (non self-hoster) families" do
    @rule.family.stubs(:self_hoster?).returns(false)

    assert_nil @executor.send(:bulk_enqueue_wait, 5)
  end

  test "bulk_enqueue_wait can be disabled with AI_ENRICHMENT_JOB_SPACING_SECONDS=0" do
    @rule.family.stubs(:self_hoster?).returns(true)

    with_env_overrides("AI_ENRICHMENT_JOB_SPACING_SECONDS" => "0") do
      assert_nil @executor.send(:bulk_enqueue_wait, 3)
    end
  end
end
