# frozen_string_literal: true

class WiseAccount::Transactions::Processor
  include WiseAccount::DataHelpers

  attr_reader :wise_account

  def initialize(wise_account)
    @wise_account = wise_account
  end

  def process
    unless wise_account.raw_transactions_payload.present?
      Rails.logger.info "WiseAccount::Transactions::Processor - No transactions in raw_transactions_payload for wise_account #{wise_account.id}"
      return { success: true, total: 0, imported: 0, failed: 0, errors: [] }
    end

    total_count = wise_account.raw_transactions_payload.count
    Rails.logger.info "WiseAccount::Transactions::Processor - Processing #{total_count} transactions for wise_account #{wise_account.id}"

    imported_count = 0
    failed_count = 0
    errors = []

    # Each entry is processed inside a transaction, but to avoid locking up the DB when
    # there are hundreds or thousands of transactions, we process them individually.
    wise_account.raw_transactions_payload.each_with_index do |transaction_data, index|
      begin
        result = process_transaction(transaction_data)

        if result.nil?
          # Transaction was skipped (e.g., no linked account or blank external_id)
          failed_count += 1
          transaction_id = transaction_data.try(:[], :id) || transaction_data.try(:[], "id") || "unknown"
          errors << { index: index, transaction_id: transaction_id, error: "Skipped" }
        else
          imported_count += 1
        end
      rescue ArgumentError => e
        # Validation error - log and continue
        failed_count += 1
        transaction_id = transaction_data.try(:[], :id) || transaction_data.try(:[], "id") || "unknown"
        error_message = "Validation error: #{e.message}"
        Rails.logger.error "WiseAccount::Transactions::Processor - #{error_message} (transaction #{transaction_id})"
        errors << { index: index, transaction_id: transaction_id, error: error_message }
      rescue => e
        # Unexpected error - log with full context and continue
        failed_count += 1
        transaction_id = transaction_data.try(:[], :id) || transaction_data.try(:[], "id") || "unknown"
        error_message = "#{e.class}: #{e.message}"
        Rails.logger.error "WiseAccount::Transactions::Processor - Error processing transaction #{transaction_id}: #{error_message}"
        Rails.logger.error e.backtrace.join("\n")
        errors << { index: index, transaction_id: transaction_id, error: error_message }
      end
    end

    result = {
      success: failed_count == 0,
      total: total_count,
      imported: imported_count,
      failed: failed_count,
      errors: errors
    }

    if failed_count > 0
      Rails.logger.warn "WiseAccount::Transactions::Processor - Completed with #{failed_count} failures out of #{total_count} transactions"
    else
      Rails.logger.info "WiseAccount::Transactions::Processor - Successfully processed #{imported_count} transactions"
    end

    result
  end

  private

    def account
      @wise_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def process_transaction(transaction_data)
      return nil unless account.present?

      data = transaction_data.with_indifferent_access

      external_id = wise_reference(data)
      return nil if external_id.blank?

      amount = parse_transaction_amount(data)
      return nil if amount.nil?

      date = parse_date(data[:date])
      return nil if date.nil?

      name = wise_name(data)
      currency = (data.dig(:amount, :currency).presence || account.currency).to_s.upcase

      Rails.logger.info "WiseAccount::Transactions::Processor - Importing transaction: id=#{external_id} amount=#{amount} date=#{date}"

      # Use ProviderImportAdapter for proper deduplication via external_id + source
      import_adapter.import_transaction(
        external_id: "wise_#{external_id}",
        amount: amount,
        currency: currency,
        date: date,
        name: name[0..254], # Limit to 255 chars
        source: "wise",
        extra: build_extra_metadata(data)
      )
    end

    def wise_reference(data)
      (data[:referenceNumber] || data[:reference_number] || data[:id]).to_s
    end

    def wise_name(data)
      details = data[:details] || {}
      details = details.with_indifferent_access if details.is_a?(Hash)

      candidate = details[:description].presence ||
                  details.dig(:merchant, :name).presence ||
                  details[:senderName].presence ||
                  data[:type].to_s.titleize.presence

      candidate.presence || "Wise transaction"
    end

    def parse_transaction_amount(data)
      value = parse_decimal(data.dig(:amount, :value))
      return nil if value.nil?

      # Wise convention: negative = money out, positive = money in.
      # Sure convention: positive = money out (expense), negative = money in.
      -value
    end

    def build_extra_metadata(data)
      details = data[:details] || {}
      details = details.with_indifferent_access if details.is_a?(Hash)

      {
        "wise" => {
          "reference_number" => data[:referenceNumber],
          "type" => data[:type],
          "detail_type" => details[:type],
          "running_balance" => data.dig(:runningBalance, :value)
        }.compact
      }
    end
end
