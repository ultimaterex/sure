# frozen_string_literal: true

class Provider::Gemini::BankStatementExtractor
  MAX_PDF_BYTES = 15 * 1024 * 1024

  attr_reader :last_usage

  def initialize(client:, model:, pdf_content:)
    @client = client
    @model = model
    @pdf_content = pdf_content
  end

  def extract
    raise Provider::Gemini::Error.new("PDF content is required", :bad_request) if @pdf_content.blank?
    if @pdf_content.bytesize > MAX_PDF_BYTES
      raise Provider::Gemini::Error.new("PDF is too large (#{@pdf_content.bytesize} bytes) for inline Gemini processing", :bad_request)
    end

    data, @last_usage = Provider::Gemini::StructuredOutput.generate(
      client: @client,
      model: @model,
      system: instructions,
      user_parts: [
        Provider::Gemini::StructuredOutput.pdf_part(@pdf_content),
        { text: "Extract every transaction from this bank statement and return the structured JSON." }
      ],
      schema: schema,
      max_tokens: max_tokens
    )

    build_result(data)
  end

  private

    def max_tokens
      ENV.fetch("GEMINI_MAX_TOKENS", 4096).to_i
    end

    def schema
      {
        type: "object",
        properties: {
          bank_name: { type: "string", nullable: true },
          account_holder: { type: "string", nullable: true },
          account_number: { type: "string", nullable: true },
          statement_period: {
            type: "object",
            properties: {
              start_date: { type: "string", nullable: true },
              end_date: { type: "string", nullable: true }
            }
          },
          opening_balance: { type: "number", nullable: true },
          closing_balance: { type: "number", nullable: true },
          transactions: {
            type: "array",
            items: {
              type: "object",
              properties: {
                date: { type: "string" },
                description: { type: "string" },
                amount: { type: "number" },
                reference: { type: "string", nullable: true },
                category: { type: "string", nullable: true }
              },
              required: [ "date", "description", "amount" ]
            }
          }
        },
        required: [ "transactions" ]
      }
    end

    def instructions
      <<~INSTRUCTIONS
        Extract bank statement data from the attached PDF and return JSON.

        Rules:
          - Extract EVERY transaction in document order
          - Negative amounts for debits / expenses, positive for credits / deposits
          - Dates in YYYY-MM-DD
          - Use null for any field you cannot read; do not invent values
      INSTRUCTIONS
    end

    def build_result(parsed)
      transactions = Array(parsed["transactions"] || parsed[:transactions]).filter_map { |t| normalize_transaction(t) }

      {
        transactions: transactions,
        period: {
          start_date: dig_period(parsed, :start_date),
          end_date: dig_period(parsed, :end_date)
        },
        account_holder: parsed["account_holder"] || parsed[:account_holder],
        account_number: parsed["account_number"] || parsed[:account_number],
        bank_name: parsed["bank_name"] || parsed[:bank_name],
        opening_balance: parsed["opening_balance"] || parsed[:opening_balance],
        closing_balance: parsed["closing_balance"] || parsed[:closing_balance]
      }
    end

    def dig_period(parsed, key)
      period = parsed["statement_period"] || parsed[:statement_period]
      return nil unless period.is_a?(Hash)

      period[key.to_s] || period[key]
    end

    def normalize_transaction(txn)
      return nil unless txn.is_a?(Hash)

      {
        date: parse_date(txn["date"] || txn[:date]),
        amount: parse_amount(txn["amount"] || txn[:amount]),
        name: txn["description"] || txn[:description] || txn["name"] || txn[:name],
        category: txn["category"] || txn[:category],
        notes: txn["reference"] || txn[:reference]
      }
    end

    def parse_date(date_str)
      return nil if date_str.blank?

      Date.parse(date_str.to_s).strftime("%Y-%m-%d")
    rescue ArgumentError
      nil
    end

    def parse_amount(amount)
      return nil if amount.nil?
      return amount.to_f if amount.is_a?(Numeric)

      amount.to_s.gsub(/[^0-9.\-]/, "").to_f
    end
end
