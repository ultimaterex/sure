# frozen_string_literal: true

class WiseAccount::Processor
  include WiseAccount::DataHelpers

  attr_reader :wise_account

  def initialize(wise_account)
    @wise_account = wise_account
  end

  def process
    account = wise_account.current_account
    return unless account

    Rails.logger.info "WiseAccount::Processor - Processing account #{wise_account.id} -> Sure account #{account.id}"

    # Update account balance FIRST (before processing transactions/holdings/activities)
    update_account_balance(account)

    # Process transactions
    transactions_count = wise_account.raw_transactions_payload&.size || 0
    Rails.logger.info "WiseAccount::Processor - Transactions payload has #{transactions_count} items"

    if wise_account.raw_transactions_payload.present?
      Rails.logger.info "WiseAccount::Processor - Processing transactions..."
      WiseAccount::Transactions::Processor.new(wise_account).process
    else
      Rails.logger.warn "WiseAccount::Processor - No transactions payload to process"
    end

    # Trigger immediate UI refresh so entries appear in the activity feed
    account.broadcast_sync_complete
    Rails.logger.info "WiseAccount::Processor - Broadcast sync complete for account #{account.id}"

    { transactions_processed: transactions_count > 0 }
  end

  private

    def update_account_balance(account)
      # Wise balances are cash (Depository): a positive balance is reported
      # positive, matching Sure's asset-account convention. No sign inversion.
      balance = wise_account.current_balance || 0

      Rails.logger.info "WiseAccount::Processor - Balance update: #{balance}"

      account.assign_attributes(
        balance: balance,
        cash_balance: balance,
        currency: wise_account.currency || account.currency
      )
      account.save!

      # Create or update the current balance anchor valuation for linked accounts
      # This is critical for reverse sync to work correctly
      account.set_current_balance(balance)
    end
end
