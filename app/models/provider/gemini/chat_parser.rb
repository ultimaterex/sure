# frozen_string_literal: true

# Parses a native Gemini generateContent response into the LlmConcept shape.
# Concatenates text parts into one message and turns functionCall parts into
# ChatFunctionRequests, capturing each part's thoughtSignature so it can be
# replayed on the follow-up request.
class Provider::Gemini::ChatParser
  ChatResponse = Provider::LlmConcept::ChatResponse
  ChatMessage = Provider::LlmConcept::ChatMessage
  ChatFunctionRequest = Provider::LlmConcept::ChatFunctionRequest

  def initialize(object)
    @object = object.is_a?(Hash) ? object.with_indifferent_access : {}
  end

  def parsed
    ChatResponse.new(
      id: response_id,
      model: @object[:modelVersion],
      messages: messages,
      function_requests: function_requests
    )
  end

  private

    def response_id
      @object[:responseId].presence || SecureRandom.uuid
    end

    def parts
      Array(@object.dig(:candidates, 0, :content, :parts))
    end

    def messages
      text = parts.filter_map { |part| part[:text] }.join
      return [] if text.blank?

      [ ChatMessage.new(id: response_id, output_text: text) ]
    end

    def function_requests
      parts.each_with_index.filter_map do |part, index|
        call = part[:functionCall]
        next unless call

        call_id = "#{response_id}-#{index}"
        ChatFunctionRequest.new(
          id: call_id,
          call_id: call_id,
          function_name: call[:name],
          function_args: (call[:args] || {}).to_json,
          # Native thought signature — must be echoed back on the replayed call.
          thought_signature: part[:thoughtSignature]
        )
      end
    end
end
