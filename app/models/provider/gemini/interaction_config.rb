# frozen_string_literal: true

# Builds a native Gemini **Interactions API** request body from the LlmConcept
# chat inputs.
#
# The Interactions API keeps conversation state server-side and is continued via
# `previous_interaction_id`. The responder passes a `previous_interaction_id`
# only on within-turn follow-ups (after executing tool calls); the first call of
# a turn gets a cross-turn id that may be stale (free-tier retention is 1 day, or
# it may belong to a different provider). So the rule is:
#
#   Use previous_interaction_id iff function_results are present.
#
# - First call (no function_results): send the full conversation as `input`
#   steps (history flattened to text, then the user's prompt). Self-contained —
#   never breaks on cross-turn expiry or a provider switch.
# - Follow-up (function_results present): send only function_result steps and
#   chain via previous_interaction_id; the server already holds this turn's
#   context (including thought signatures).
#
# `tools` and `system_instruction` are interaction-scoped and must be resent on
# every call. `store` is left at the API default (true) so the within-turn
# previous_interaction_id works.
class Provider::Gemini::InteractionConfig
  # Gemini's function-declaration schema is a strict OpenAPI subset and rejects
  # JSON-Schema keywords the app's tool definitions include. Strip them
  # recursively; everything Gemini understands passes through untouched.
  UNSUPPORTED_SCHEMA_KEYS = %w[
    additionalProperties uniqueItems $schema $id $ref definitions
    patternProperties strict exclusiveMinimum exclusiveMaximum const
  ].freeze

  def initialize(
    prompt:,
    instructions: nil,
    functions: [],
    function_results: [],
    conversation_history: [],
    previous_interaction_id: nil,
    default_max_tokens: 4096
  )
    @prompt = prompt
    @instructions = instructions
    @functions = functions || []
    @function_results = function_results || []
    @conversation_history = conversation_history || []
    @previous_interaction_id = previous_interaction_id
    @default_max_tokens = default_max_tokens
  end

  def build_request(model:)
    body = {
      model: model,
      input: input,
      generation_config: { max_output_tokens: @default_max_tokens }
    }
    body[:system_instruction] = @instructions if @instructions.present?
    body[:tools] = tools if tools.present?
    body[:previous_interaction_id] = @previous_interaction_id if follow_up? && @previous_interaction_id.present?
    body
  end

  private

    def follow_up?
      @function_results.present?
    end

    def input
      return function_result_steps if follow_up?

      history_steps + [ user_input_step(@prompt) ]
    end

    def function_result_steps
      @function_results.map do |result|
        {
          type: "function_result",
          call_id: result[:call_id],
          name: result[:name],
          result: [ { type: "text", text: serialize_output(result[:output]) } ]
        }
      end
    end

    # Prior completed turns, flattened to text steps (mirrors how the chat's
    # generateContent path represented history). Tool structure from past turns
    # is not replayed; the current turn's tool round-trip is chained server-side.
    def history_steps
      @conversation_history.filter_map do |record|
        text = record.respond_to?(:content) ? record.content.to_s : record.to_s
        next if text.blank?

        { type: step_type(record), content: [ { type: "text", text: text } ] }
      end
    end

    def user_input_step(text)
      { type: "user_input", content: [ { type: "text", text: text.to_s } ] }
    end

    def step_type(record)
      role = record.respond_to?(:role) ? record.role.to_s : "user"
      role == "assistant" ? "model_output" : "user_input"
    end

    def tools
      return [] if @functions.empty?

      @functions.map do |fn|
        tool = { type: "function", name: fn[:name], description: fn[:description] }
        params = fn[:params_schema]
        tool[:parameters] = sanitize_schema(params) if params.present?
        tool
      end
    end

    def serialize_output(output)
      case output
      when nil then ""
      when String then output
      else output.to_json
      end
    end

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
end
