# frozen_string_literal: true

# Builds a native Gemini `generateContent` request body from the LlmConcept
# chat inputs. Gemini is stateless: every request carries the full `contents`
# (roles user|model, each with `parts`). Tool calls replay as a `model`
# functionCall part (with its `thoughtSignature`) followed by a `user`
# functionResponse part.
class Provider::Gemini::ChatConfig
  def initialize(prompt:, instructions: nil, functions: [], function_results: [], conversation_history: [], default_max_tokens: 4096)
    @prompt = prompt
    @instructions = instructions
    @functions = functions || []
    @function_results = function_results || []
    @conversation_history = conversation_history || []
    @default_max_tokens = default_max_tokens
  end

  def build_request(model:, cached_content: nil)
    body = { contents: contents }
    if cached_content.present?
      # The stable system instruction + tools live in the referenced cache, so
      # they're omitted from the request body (that's where the savings come from).
      body[:cachedContent] = cached_content
    else
      body[:systemInstruction] = system_instruction if system_instruction
      body[:tools] = tools if tools.present?
    end
    body[:generationConfig] = { maxOutputTokens: @default_max_tokens }
    { model: model, body: body }
  end

  # Stable across a chat turn — exposed so the context cache can store the same
  # payload the request would otherwise inline.
  def system_instruction
    return nil if @instructions.blank?

    { parts: [ { text: @instructions } ] }
  end

  def tools
    return [] if @functions.empty?

    declarations = @functions.map do |fn|
      declaration = { name: fn[:name], description: fn[:description] }
      params = fn[:params_schema]
      declaration[:parameters] = sanitize_schema(params) if params.present?
      declaration
    end

    [ { functionDeclarations: declarations } ]
  end

  private

    def contents
      list = history_contents
      list << { role: "user", parts: [ { text: @prompt } ] } if @prompt.present?
      list.concat(function_exchange_contents)
      list
    end

    # Prior completed turns, mapped to text parts. Tool structure within past
    # turns is flattened to text; the CURRENT turn's tool round-trip is carried
    # precisely via `function_exchange_contents`.
    def history_contents
      @conversation_history.filter_map do |record|
        text = record.respond_to?(:content) ? record.content.to_s : record.to_s
        next if text.blank?

        role = gemini_role(record)
        { role: role, parts: [ { text: text } ] }
      end
    end

    # Replays this turn's tool calls so the model can continue. The model's
    # functionCall must carry back its thoughtSignature or Gemini rejects it.
    def function_exchange_contents
      return [] if @function_results.empty?

      model_parts = @function_results.map do |result|
        part = { functionCall: { name: result[:name], args: parse_args(result[:arguments]) } }
        part[:thoughtSignature] = result[:thought_signature] if result[:thought_signature].present?
        part
      end

      response_parts = @function_results.map do |result|
        { functionResponse: { name: result[:name], response: response_payload(result[:output]) } }
      end

      [
        { role: "model", parts: model_parts },
        { role: "user", parts: response_parts }
      ]
    end

    # Gemini's function-declaration schema is a strict OpenAPI 3.0 subset and
    # rejects JSON-Schema keywords the app's tool definitions include (e.g.
    # `additionalProperties`, `uniqueItems`). Strip the unsupported keys
    # recursively; everything Gemini understands passes through untouched.
    UNSUPPORTED_SCHEMA_KEYS = %w[
      additionalProperties uniqueItems $schema $id $ref definitions
      patternProperties strict exclusiveMinimum exclusiveMaximum const
    ].freeze

    def sanitize_schema(node)
      case node
      when Hash
        node.each_with_object({}) do |(key, value), acc|
          next if UNSUPPORTED_SCHEMA_KEYS.include?(key.to_s)

          acc[key] = sanitize_schema(value)
        end
      when Array
        node.map { |item| sanitize_schema(item) }
      else
        node
      end
    end

    def gemini_role(record)
      role = record.respond_to?(:role) ? record.role.to_s : "user"
      role == "assistant" ? "model" : "user"
    end

    def parse_args(arguments)
      return arguments if arguments.is_a?(Hash)
      return {} if arguments.blank?

      JSON.parse(arguments)
    rescue JSON::ParserError
      {}
    end

    # Gemini's functionResponse.response must be a JSON object.
    def response_payload(output)
      return output if output.is_a?(Hash)
      return {} if output.nil?

      parsed = JSON.parse(output) rescue nil
      parsed.is_a?(Hash) ? parsed : { result: output.to_s }
    end
end
