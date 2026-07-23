# frozen_string_literal: true

class Provider::Gemini::PdfProcessor
  PdfProcessingResult = Provider::LlmConcept::PdfProcessingResult

  # Gemini caps an inline request payload at ~20 MB. The base64-encoded PDF
  # (~4/3 larger) travels in that body, so cap the raw bytes conservatively.
  MAX_PDF_BYTES = 15 * 1024 * 1024

  attr_reader :last_usage

  def initialize(client, model:, pdf_content:)
    @client = client
    @model = model
    @pdf_content = pdf_content
  end

  def process
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
        { text: "Analyze the attached document and return the structured JSON." }
      ],
      schema: schema,
      max_tokens: max_tokens
    )

    PdfProcessingResult.new(
      summary: data["summary"] || data[:summary],
      document_type: normalize_document_type(data["document_type"] || data[:document_type]),
      extracted_data: data["extracted_data"] || data[:extracted_data] || {}
    )
  end

  private

    def max_tokens
      ENV.fetch("GEMINI_MAX_TOKENS", 4096).to_i
    end

    def schema
      {
        type: "object",
        properties: {
          document_type: { type: "string", enum: Import::DOCUMENT_TYPES },
          summary: { type: "string" },
          extracted_data: {
            type: "object",
            properties: {
              institution_name: { type: "string", nullable: true },
              statement_period_start: { type: "string", nullable: true },
              statement_period_end: { type: "string", nullable: true },
              transaction_count: { type: "integer", nullable: true },
              opening_balance: { type: "number", nullable: true },
              closing_balance: { type: "number", nullable: true },
              currency: { type: "string", nullable: true },
              account_holder: { type: "string", nullable: true }
            }
          }
        },
        required: [ "document_type", "summary", "extracted_data" ]
      }
    end

    def instructions
      <<~INSTRUCTIONS
        You analyze financial documents. For the attached PDF, classify the document type,
        summarize it, and extract key metadata. Return JSON.

        Classification options:
          - bank_statement: bank account statements (incl. mobile money / digital wallets)
          - credit_card_statement: credit card statements
          - investment_statement: brokerage / investment statements
          - financial_document: tax forms, receipts, invoices, financial reports
          - contract: legal agreements, loans, terms of service
          - other: anything else

        Rules:
          - Be factual; only report what is clearly visible
          - If a field is unclear/redacted, return null for it
          - Do not invent figures or names you cannot read
          - For statements with many transactions, return the count rather than enumerating them
      INSTRUCTIONS
    end

    def normalize_document_type(doc_type)
      return "other" if doc_type.blank?

      normalized = doc_type.to_s.strip.downcase.gsub(/\s+/, "_")
      Import::DOCUMENT_TYPES.include?(normalized) ? normalized : "other"
    end
end
