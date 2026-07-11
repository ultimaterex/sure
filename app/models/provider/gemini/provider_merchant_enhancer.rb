# frozen_string_literal: true

class Provider::Gemini::ProviderMerchantEnhancer
  EnhancedMerchant = Provider::LlmConcept::EnhancedMerchant

  attr_reader :last_usage

  def initialize(client, model:, merchants: [])
    @client = client
    @model = model
    @merchants = merchants
  end

  def enhance_merchants
    data, @last_usage = Provider::Gemini::StructuredOutput.generate(
      client: @client,
      model: @model,
      system: instructions,
      user_parts: [ { text: user_message } ],
      schema: schema,
      max_tokens: max_tokens
    )

    rows(data).map do |m|
      EnhancedMerchant.new(
        merchant_id: m["merchant_id"] || m[:merchant_id],
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
                merchant_id: { type: "string" },
                business_url: { type: "string", nullable: true }
              },
              required: [ "merchant_id", "business_url" ]
            }
          }
        },
        required: [ "merchants" ]
      }
    end

    def instructions
      <<~INSTRUCTIONS
        You are an assistant to a consumer personal finance app. Given a list of merchant names, identify
        the business website URL for each and return JSON.

        Follow ALL the rules below:

        - One result per merchant, correlated by merchant_id
        - Do NOT include the www. subdomain ("walmart.com", not "www.walmart.com")
        - Favor null over false positives; only return a URL when 80%+ confident
        - NEVER return a URL for generic or local-only merchants ("Local diner", "Gas station", "ATM withdrawal")
      INSTRUCTIONS
    end

    def user_message
      <<~MESSAGE
        Enhance the following merchants by identifying each one's website URL:

        ```json
        #{@merchants.to_json}
        ```
      MESSAGE
    end

    def normalize_value(value)
      return nil if value.nil?

      str = value.to_s.strip
      return nil if str.empty? || str.casecmp("null").zero?

      str
    end
end
