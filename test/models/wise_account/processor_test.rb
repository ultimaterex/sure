# frozen_string_literal: true

require "test_helper"

class WiseAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(
      name: "Wise USD", balance: 0, currency: "USD", accountable: Depository.new
    )
    @item = @family.wise_items.create!(name: "Wise", api_token: "tok")
    @wise_account = @item.wise_accounts.create!(
      name: "Wise USD", wise_account_id: "bal_usd", currency: "USD", current_balance: 500
    )
    AccountProvider.create!(provider: @wise_account, account: @account)
    @wise_account.reload
  end

  # ---------------------------------------------------------------------------
  # balance (Depository — no sign inversion)
  # ---------------------------------------------------------------------------

  test "updates account balance without negation" do
    @wise_account.update!(current_balance: 750)

    WiseAccount::Processor.new(@wise_account).process

    assert_in_delta 750, @account.reload.balance.to_f, 0.01
  end

  # ---------------------------------------------------------------------------
  # transaction sign conversion (Wise: out = negative; Sure: out = positive)
  # ---------------------------------------------------------------------------

  test "debit (negative Wise amount) becomes positive outflow" do
    @wise_account.update!(raw_transactions_payload: [ stmt_txn(reference: "R1", value: -25.50) ])

    result = WiseAccount::Transactions::Processor.new(@wise_account).process

    assert result[:success]
    entry = entry_for("wise_R1")
    assert entry, "expected an entry to be imported"
    assert entry.amount.positive?, "a debit must be a positive outflow"
    assert_in_delta 25.50, entry.amount.to_f, 0.01
  end

  test "credit (positive Wise amount) becomes negative inflow" do
    @wise_account.update!(raw_transactions_payload: [ stmt_txn(reference: "R2", value: 100.00) ])

    WiseAccount::Transactions::Processor.new(@wise_account).process

    entry = entry_for("wise_R2")
    assert entry.amount.negative?, "a credit must be a negative inflow"
    assert_in_delta(-100.00, entry.amount.to_f, 0.01)
  end

  test "stores wise metadata in extra" do
    @wise_account.update!(raw_transactions_payload: [ stmt_txn(reference: "R3", value: -5) ])

    WiseAccount::Transactions::Processor.new(@wise_account).process

    extra = entry_for("wise_R3").entryable.extra
    assert_equal "R3", extra.dig("wise", "reference_number")
    assert_equal "DEBIT", extra.dig("wise", "type")
  end

  test "skips a line missing a reference number" do
    @wise_account.update!(raw_transactions_payload: [ { "type" => "DEBIT", "amount" => { "value" => -5, "currency" => "USD" } } ])

    result = WiseAccount::Transactions::Processor.new(@wise_account).process

    assert_equal 0, result[:imported]
  end

  test "is idempotent across re-processing" do
    @wise_account.update!(raw_transactions_payload: [ stmt_txn(reference: "R4", value: -10) ])
    WiseAccount::Transactions::Processor.new(@wise_account).process

    assert_no_difference "@account.entries.count" do
      WiseAccount::Transactions::Processor.new(@wise_account).process
    end
  end

  test "returns empty result when there are no transactions" do
    @wise_account.update!(raw_transactions_payload: [])

    result = WiseAccount::Transactions::Processor.new(@wise_account).process

    assert result[:success]
    assert_equal 0, result[:total]
  end

  private

    def entry_for(external_id)
      @account.entries.find_by(external_id: external_id, source: "wise")
    end

    def stmt_txn(reference:, value:, currency: "USD", date: "2024-06-01T00:00:00Z", description: "Test")
      {
        "type" => (value.negative? ? "DEBIT" : "CREDIT"),
        "date" => date,
        "amount" => { "value" => value, "currency" => currency },
        "referenceNumber" => reference,
        "details" => { "description" => description }
      }
    end
end
