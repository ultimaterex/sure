# frozen_string_literal: true

class Provider::Gemini::AutoMerchantDetector
  AutoDetectedMerchant = Provider::LlmConcept::AutoDetectedMerchant

  attr_reader :last_usage

  def initialize(client, model:, transactions: [], user_merchants: [])
    @client = client
    @model = model
    @transactions = transactions
    @user_merchants = user_merchants
  end

  def auto_detect_merchants
    data, @last_usage = Provider::Gemini::StructuredOutput.generate(
      client: @client,
      model: @model,
      system: instructions,
      user_parts: [ { text: user_message } ],
      schema: schema,
      max_tokens: max_tokens
    )

    rows(data).map do |m|
      AutoDetectedMerchant.new(
        transaction_id: m["transaction_id"] || m[:transaction_id],
        business_name: normalize_merchant_name(m["business_name"] || m[:business_name]),
        business_url: normalize_value(m["business_url"] || m[:business_url])
      )
    end
  end

  private

    def rows(data)
      data.is_a?(Hash) ? Array(data["merchants"] || data[:merchants]) : []
    end

    def max_tokens
      ENV.fetch("GEMINI_MAX_TOKENS", 4096).to_i
    end

    def schema
      {
        type: "object",
        properties: {
          merchants: {
            type: "array",
            items: {
              type: "object",
              properties: {
                transaction_id: { type: "string" },
                business_name: { type: "string", nullable: true },
                business_url: { type: "string", nullable: true }
              },
              required: [ "transaction_id", "business_name", "business_url" ]
            }
          }
        },
        required: [ "merchants" ]
      }
    end

    def instructions
      <<~INSTRUCTIONS
        You are an assistant to a consumer personal finance app. Detect the business name and website URL
        for each transaction and return JSON.

        Follow ALL the rules below:

        - One result per transaction, correlated by transaction_id
        - Do NOT include the www. subdomain in business_url ("amazon.com", not "www.amazon.com")
        - User-provided merchants should only be used when the match is unambiguous
        - Favor null over false positives; only return values when 80%+ confident
        - NEVER return a name/URL for generic descriptions ("Paycheck", "Local diner", "ATM", "POS DEBIT")

        Decision order:
          1. Identify from your knowledge of global businesses
          2. Otherwise, match against the user-provided merchants
          3. Otherwise, return null for both fields
      INSTRUCTIONS
    end

    def user_message
      <<~MESSAGE
        User's known merchants:

        ```json
        #{@user_merchants.to_json}
        ```

        Transactions to analyze:

        ```json
        #{@transactions.to_json}
        ```
      MESSAGE
    end

    def normalize_value(value)
      return nil if value.nil?

      str = value.to_s.strip
      return nil if str.empty? || str.casecmp("null").zero?

      str
    end

    def normalize_merchant_name(value)
      str = normalize_value(value)
      return nil unless str
      return str if @user_merchants.blank?

      match = @user_merchants.find { |m| m[:name].to_s.casecmp(str).zero? }
      match ? match[:name] : str
    end
end
