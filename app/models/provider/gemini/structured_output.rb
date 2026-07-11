# frozen_string_literal: true

# Shared helper for Gemini's structured-output features. Sends a single-turn
# generateContent request that forces a JSON response conforming to `schema`
# (native `responseMimeType` + `responseSchema`), then parses the JSON text.
module Provider::Gemini::StructuredOutput
  module_function

  # @param user_parts [Array<Hash>] Gemini parts ({text:} and/or {inlineData:}).
  # @return [Array(Hash, Hash)] parsed JSON data and the usage hash.
  def generate(client:, model:, system:, user_parts:, schema:, max_tokens: 4096)
    body = {
      contents: [ { role: "user", parts: user_parts } ],
      generationConfig: {
        responseMimeType: "application/json",
        responseSchema: schema,
        maxOutputTokens: max_tokens
      }
    }
    body[:systemInstruction] = { parts: [ { text: system } ] } if system.present?

    raw = client.generate_content(model: model, body: body)

    text = Array(raw.dig("candidates", 0, "content", "parts")).filter_map { |part| part["text"] }.join
    raise Provider::Gemini::Error.new("Gemini returned an empty structured response", :empty_response) if text.blank?

    data = JSON.parse(text)
    usage = Provider::Gemini::Usage.from_metadata(raw["usageMetadata"])
    [ data, usage ]
  rescue JSON::ParserError => e
    raise Provider::Gemini::Error.new("Gemini returned invalid JSON: #{e.message}", :invalid_json)
  end

  # Wraps a PDF as a Gemini inlineData part.
  def pdf_part(pdf_content)
    { inlineData: { mimeType: "application/pdf", data: Base64.strict_encode64(pdf_content) } }
  end
end
