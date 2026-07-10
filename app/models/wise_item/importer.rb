# frozen_string_literal: true

class WiseItem::Importer
  include SyncStats::Collector
  include WiseAccount::DataHelpers

  attr_reader :wise_item, :wise_provider, :sync

  def initialize(wise_item, wise_provider:, sync: nil)
    @wise_item = wise_item
    @wise_provider = wise_provider
    @sync = sync
  end

  class CredentialsError < StandardError; end

  def import
    Rails.logger.info "WiseItem::Importer - Starting import for item #{wise_item.id}"

    credentials = wise_item.wise_credentials
    unless credentials
      raise CredentialsError, "No Wise credentials configured for item #{wise_item.id}"
    end

    # Step 1: Fetch and store all accounts
    import_accounts(credentials)

    # Step 2: For LINKED accounts only, fetch data
    # Unlinked accounts just need basic info (name, balance) for the setup modal
    linked_accounts = WiseAccount
      .where(wise_item_id: wise_item.id)
      .joins(:account_provider)

    Rails.logger.info "WiseItem::Importer - Found #{linked_accounts.count} linked accounts to process"

    linked_accounts.each do |wise_account|
      Rails.logger.info "WiseItem::Importer - Processing linked account #{wise_account.id}"
      import_account_data(wise_account, credentials)
    end

    # Update raw payload on the item
    wise_item.upsert_wise_snapshot!(stats)
  rescue Provider::Wise::AuthenticationError => e
    wise_item.update!(status: :requires_update)
    raise
  end

  private

    def stats
      @stats ||= {}
    end

    def persist_stats!
      return unless sync&.respond_to?(:sync_stats)
      merged = (sync.sync_stats || {}).merge(stats)
      sync.update_columns(sync_stats: merged)
    end

    def import_accounts(credentials)
      Rails.logger.info "WiseItem::Importer - Fetching profiles and balances"

      # A Wise token may expose multiple profiles (personal + business); each
      # profile holds one balance account per currency. Each balance becomes a
      # wise_account, tagged with its owning profile_id for later statement calls.
      profiles = Array.wrap(wise_provider.get_profiles)
      stats["api_requests"] = stats.fetch("api_requests", 0) + 1

      upstream_account_ids = []
      total_accounts = 0

      profiles.each do |profile|
        profile_id = profile[:id]
        next if profile_id.blank?

        balances = Array.wrap(wise_provider.get_balances(profile_id))
        stats["api_requests"] = stats.fetch("api_requests", 0) + 1

        balances.each do |balance|
          total_accounts += 1
          begin
            import_account(balance.merge(profile_id: profile_id), credentials)
            upstream_account_ids << balance[:id].to_s if balance[:id]
          rescue => e
            Rails.logger.error "WiseItem::Importer - Failed to import balance #{balance[:id]}: #{e.message}"
            stats["accounts_skipped"] = stats.fetch("accounts_skipped", 0) + 1
            register_error(e, account_data: balance)
          end
        end
      end

      stats["total_accounts"] = total_accounts
      persist_stats!

      # Clean up accounts that no longer exist upstream
      prune_removed_accounts(upstream_account_ids)
    end

    def import_account(balance_data, credentials)
      wise_account_id = balance_data[:id].to_s
      return if wise_account_id.blank?

      wise_account = wise_item.wise_accounts.find_or_initialize_by(
        wise_account_id: wise_account_id
      )
      wise_account.upsert_from_wise!(balance_data)

      stats["accounts_imported"] = stats.fetch("accounts_imported", 0) + 1
    end

    def import_account_data(wise_account, credentials)
      # Import transactions
      import_transactions(wise_account, credentials)
    end

    def import_transactions(wise_account, credentials)
      Rails.logger.info "WiseItem::Importer - Fetching transactions for account #{wise_account.id}"

      begin
        # Determine date range
        start_date = calculate_transaction_start_date(wise_account)
        end_date = Date.current

        profile_id = wise_account.institution_metadata&.with_indifferent_access&.dig(:profile_id)
        statement = wise_provider.get_balance_statement(
          profile_id: profile_id,
          balance_id: wise_account.wise_account_id,
          currency: wise_account.currency,
          start_date: start_date,
          end_date: end_date
        )
        transactions_data = Array.wrap(statement.is_a?(Hash) ? statement[:transactions] : nil)

        stats["api_requests"] = stats.fetch("api_requests", 0) + 1

        if transactions_data.any?
          # Convert SDK objects to hashes and merge with existing
          transactions_hashes = transactions_data.map { |t| sdk_object_to_hash(t) }
          merged = merge_transactions(wise_account.raw_transactions_payload || [], transactions_hashes)
          wise_account.upsert_wise_transactions_snapshot!(merged)
          stats["transactions_found"] = stats.fetch("transactions_found", 0) + transactions_data.size
        end
      rescue => e
        Rails.logger.warn "WiseItem::Importer - Failed to fetch transactions: #{e.message}"
        register_error(e, context: "transactions", account_id: wise_account.id)
      end
    end

    def calculate_transaction_start_date(wise_account)
      # Use user-specified start date if available
      user_start = wise_account.sync_start_date
      return user_start if user_start.present?

      # For accounts with existing transactions, use incremental sync
      existing_count = (wise_account.raw_transactions_payload || []).size
      if existing_count >= 10 && wise_item.last_synced_at.present?
        # Incremental: go back 7 days from last sync to catch updates
        (wise_item.last_synced_at - 7.days).to_date
      else
        # Full sync: go back 90 days
        90.days.ago.to_date
      end
    end

    def merge_transactions(existing, new_transactions)
      # Merge by ID, preferring newer data
      by_id = {}
      existing.each { |t| by_id[transaction_key(t)] = t }
      new_transactions.each { |t| by_id[transaction_key(t)] = t }
      by_id.values
    end

    def transaction_key(transaction)
      transaction = transaction.with_indifferent_access if transaction.is_a?(Hash)
      # Wise statement lines are keyed by referenceNumber.
      transaction[:referenceNumber] || transaction[:id] ||
        [ transaction[:date], transaction.dig(:amount, :value), transaction[:type] ].join("-")
    end

    def prune_removed_accounts(upstream_account_ids)
      return if upstream_account_ids.empty?

      # Find accounts that exist locally but not upstream
      removed = wise_item.wise_accounts
        .where.not(wise_account_id: upstream_account_ids)

      if removed.any?
        Rails.logger.info "WiseItem::Importer - Pruning #{removed.count} removed accounts"
        removed.destroy_all
      end
    end

    def register_error(error, **context)
      stats["errors"] ||= []
      stats["errors"] << {
        message: error.message,
        context: context.to_s,
        timestamp: Time.current.iso8601
      }
    end
end
