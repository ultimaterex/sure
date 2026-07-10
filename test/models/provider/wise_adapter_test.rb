# frozen_string_literal: true

require "test_helper"

class Provider::WiseAdapterTest < ActiveSupport::TestCase
  test "supports Depository accounts" do
    assert_includes Provider::WiseAdapter.supported_account_types, "Depository"
  end

  test "does not support Investment accounts" do
    assert_not_includes Provider::WiseAdapter.supported_account_types, "Investment"
  end

  test "build_provider returns nil when family is nil" do
    assert_nil Provider::WiseAdapter.build_provider(family: nil)
  end

  test "build_provider returns nil when family has no wise items" do
    assert_nil Provider::WiseAdapter.build_provider(family: families(:empty))
  end

  test "build_provider returns a Wise provider when credentials configured" do
    family = families(:empty)
    family.wise_items.create!(name: "Wise", api_token: "  tok  ")

    provider = Provider::WiseAdapter.build_provider(family: family)

    assert_instance_of Provider::Wise, provider
    assert_equal "tok", provider.api_token
  end
end
