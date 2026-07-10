# frozen_string_literal: true

class WiseAccount < ApplicationRecord
  include CurrencyNormalizable
  include WiseAccount::DataHelpers

  belongs_to :wise_item

  # Association through account_providers
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, presence: true

  # Scopes
  scope :with_linked, -> { joins(:account_provider) }
  scope :without_linked, -> { left_joins(:account_provider).where(account_providers: { id: nil }) }
  scope :ordered, -> { order(created_at: :desc) }

  # Callbacks
  after_destroy :enqueue_connection_cleanup

  # Helper to get account using account_providers system
  def current_account
    account
  end

  # Idempotently create or update AccountProvider link
  # CRITICAL: After creation, reload association to avoid stale nil
  def ensure_account_provider!(linked_account)
    return nil unless linked_account

    provider = account_provider || build_account_provider
    provider.account = linked_account
    provider.save!

    # Reload to clear cached nil value
    reload_account_provider
    account_provider
  end

  # Map a Wise *balance account* (one per currency, under a profile) onto a
  # wise_account row. `account_data` is a balance object from
  # Provider::Wise#get_balances, merged with the owning `profile_id`.
  def upsert_from_wise!(account_data)
    data = sdk_object_to_hash(account_data).with_indifferent_access

    currency = (data.dig(:amount, :currency) || data[:currency]).to_s.upcase
    profile_id = data[:profile_id]&.to_s

    update!(
      wise_account_id: data[:id].to_s,
      name: wise_balance_name(data, currency),
      current_balance: parse_decimal(data.dig(:amount, :value)),
      currency: currency.presence || "USD",
      account_status: "active",
      account_type: data[:type],
      provider: "wise",
      institution_metadata: {
        name: "Wise",
        domain: "wise.com",
        url: "https://wise.com",
        profile_id: profile_id,
        currency: currency,
        balance_type: data[:type]
      }.compact,
      raw_payload: account_data
    )
  end

  def upsert_wise_transactions_snapshot!(transactions_snapshot)
    assign_attributes(
      raw_transactions_payload: transactions_snapshot
    )

    save!
  end

  private

    def wise_balance_name(data, currency)
      data[:name].presence || (currency.present? ? "Wise #{currency}" : "Wise Balance")
    end

    def enqueue_connection_cleanup
      return unless wise_item

      WiseConnectionCleanupJob.perform_later(
        wise_item_id: wise_item.id,
        account_id: id
      )
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for Wise account #{id}, defaulting to USD")
    end
end
