# frozen_string_literal: true

# Parses a native Gemini **Interactions API** resource into the LlmConcept
# shape. The interaction is a chronological list of typed `steps`; we pull text
# out of `model_output` steps and turn `function_call` steps into
# ChatFunctionRequests. Server-side state (via previous_interaction_id) carries
# thought signatures, so none are echoed back here.
class Provider::Gemini::InteractionParser
  ChatResponse = Provider::LlmConcept::ChatResponse
  ChatMessage = Provider::LlmConcept::ChatMessage
  ChatFunctionRequest = Provider::LlmConcept::ChatFunctionRequest

  def initialize(object)
    @object = object.is_a?(Hash) ? object.with_indifferent_access : {}
  end

  def parsed
    ChatResponse.new(
      id: interaction_id,
      model: @object[:model],
      messages: messages,
      function_requests: function_requests
    )
  end

  private

    def interaction_id
      @object[:id].presence || SecureRandom.uuid
    end

    def steps
      Array(@object[:steps])
    end

    def messages
      text = model_output_text
      return [] if text.blank?

      [ ChatMessage.new(id: interaction_id, output_text: text) ]
    end

    # Concatenate every text block across all model_output steps. `output_text`
    # is an SDK-only convenience and is absent from the raw REST resource.
    def model_output_text
      steps.select { |step| step[:type] == "model_output" }.flat_map do |step|
        Array(step[:content]).filter_map { |block| block[:text] if block[:type] == "text" }
      end.join
    end

    def function_requests
      steps.filter_map do |step|
        next unless step[:type] == "function_call"

        # The function_call step's own `id` is what a function_result must echo
        # back as `call_id`.
        call_id = step[:id].presence || SecureRandom.uuid
        ChatFunctionRequest.new(
          id: call_id,
          call_id: call_id,
          function_name: step[:name],
          function_args: normalize_args(step[:arguments])
        )
      end
    end

    # Interactions return `arguments` as a JSON object; downstream expects the
    # JSON-string form the other providers produce.
    def normalize_args(arguments)
      return arguments if arguments.is_a?(String)

      (arguments || {}).to_json
    end
end
