# frozen_string_literal: true

class Provider::Gemini::AutoCategorizer
  AutoCategorization = Provider::LlmConcept::AutoCategorization

  attr_reader :last_usage

  def initialize(client, model:, transactions: [], user_categories: [])
    @client = client
    @model = model
    @transactions = transactions
    @user_categories = user_categories
  end

  def auto_categorize
    data, @last_usage = Provider::Gemini::StructuredOutput.generate(
      client: @client,
      model: @model,
      system: instructions,
      user_parts: [ { text: user_message } ],
      schema: schema,
      max_tokens: max_tokens
    )

    rows(data).map do |c|
      AutoCategorization.new(
        transaction_id: c["transaction_id"] || c[:transaction_id],
        category_name: normalize_category(c["category_name"] || c[:category_name])
      )
    end
  end

  private

    def rows(data)
      data.is_a?(Hash) ? Array(data["categorizations"] || data[:categorizations]) : []
    end

    def max_tokens
      ENV.fetch("GEMINI_MAX_TOKENS", 4096).to_i
    end

    def schema
      {
        type: "object",
        properties: {
          categorizations: {
            type: "array",
            items: {
              type: "object",
              properties: {
                transaction_id: { type: "string" },
                category_name: { type: "string", nullable: true }
              },
              required: [ "transaction_id", "category_name" ]
            }
          }
        },
        required: [ "categorizations" ]
      }
    end

    def instructions
      <<~INSTRUCTIONS
        You are an assistant to a consumer personal finance app. You will be provided a list of the user's
        transactions and a list of the user's categories. Auto-categorize each transaction and return JSON.

        Follow ALL the rules below:

        - Return one result per transaction, correlated by transaction_id
        - Use the most specific category possible (subcategory over parent category)
        - Use ONLY category names from the provided list, or null
        - Any category may be used regardless of whether the transaction is income or expense
        - Return null for category_name when you are not 60%+ confident, or when the description is
          generic/ambiguous (e.g., "POS DEBIT", "ACH WITHDRAWAL", "CHECK #1234")
        - The `hint` field on a transaction (when present) comes from third-party aggregators and may
          or may not match the user's categories — treat it as a weak signal
      INSTRUCTIONS
    end

    def user_message
      <<~MESSAGE
        Here are the user's available categories in JSON:

        ```json
        #{@user_categories.to_json}
        ```

        Auto-categorize the following transactions:

        ```json
        #{@transactions.to_json}
        ```
      MESSAGE
    end

    def normalize_category(value)
      return nil if value.nil?

      str = value.to_s.strip
      return nil if str.empty? || str.casecmp("null").zero?

      match = @user_categories.find { |c| c[:name].to_s.casecmp(str).zero? }
      match ? match[:name] : str
    end
end
