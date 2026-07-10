# frozen_string_literal: true

require "test_helper"

# Proves that Wise-imported currency-conversion legs are shaped so Sure's
# built-in cross-currency transfer matcher pairs them (see the Wise design
# spec §7 — the provider relies on Family#auto_match_transfers! rather than a
# bespoke detector).
class WiseAccount::TransferMatchingTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @item = @family.wise_items.create!(name: "Wise", api_token: "tok")
    @usd_account, @usd_wa = link_balance("USD", "bal_usd")
    @eur_account, @eur_wa = link_balance("EUR", "bal_eur")
  end

  test "a conversion's two legs are auto-matched into a cross-currency transfer" do
    date = Date.new(2024, 6, 1)
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date: date, rate: 0.92)

    # USD balance: money out (debit) -> Sure +100 outflow
    import_leg(@usd_wa, reference: "CONV-USD", value: -100.00, currency: "USD", date: date)
    # EUR balance: money in (credit) -> Sure -92 inflow
    import_leg(@eur_wa, reference: "CONV-EUR", value: 92.00, currency: "EUR", date: date)

    assert_difference "Transfer.count", 1 do
      @family.auto_match_transfers!
    end

    transfer = Transfer.order(:created_at).last
    assert_equal @eur_account, transfer.to_account, "destination (inflow) should be the EUR balance"
    assert_equal @usd_account, transfer.from_account, "source (outflow) should be the USD balance"
  end

  private

    def link_balance(currency, balance_id)
      account = @family.accounts.create!(
        name: "Wise #{currency}", balance: 0, currency: currency, accountable: Depository.new
      )
      wise_account = @item.wise_accounts.create!(
        name: "Wise #{currency}", wise_account_id: balance_id, currency: currency, current_balance: 0
      )
      AccountProvider.create!(provider: wise_account, account: account)
      wise_account.reload
      [ account, wise_account ]
    end

    def import_leg(wise_account, reference:, value:, currency:, date:)
      wise_account.update!(raw_transactions_payload: [ {
        "type" => (value.negative? ? "DEBIT" : "CREDIT"),
        "date" => date.to_s,
        "amount" => { "value" => value, "currency" => currency },
        "referenceNumber" => reference,
        "details" => { "description" => "Conversion" }
      } ])
      WiseAccount::Transactions::Processor.new(wise_account).process
    end
end
