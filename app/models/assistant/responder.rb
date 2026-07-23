class Assistant::Responder
  def initialize(message:, instructions:, function_tool_caller:, llm:)
    @message = message
    @instructions = instructions
    @function_tool_caller = function_tool_caller
    @llm = llm
  end

  def on(event_name, &block)
    listeners[event_name.to_sym] << block
  end

  # Cap on sequential tool-call rounds within a single turn. Thinking models
  # (e.g. Gemini) chain tool calls — call a tool, read the result, call another —
  # so a turn needs more than one round-trip. Without a limit a turn could loop
  # and run up spend, so we stop after MAX_TOOL_CALL_ROUNDS and let the model
  # answer with what it has (or surface a graceful message).
  MAX_TOOL_CALL_ROUNDS = 5

  def respond(previous_response_id: nil)
    # The provider streams output text through `text_streamer`; we drive control
    # flow off each response's return value instead (works for both the streaming
    # native path and the synchronous generic/custom-provider path).
    @text_emitted = false
    executed_tool_calls = []

    response = get_llm_response(streamer: text_streamer, previous_response_id: previous_response_id)

    rounds = 0
    while response.function_requests.any? && rounds < MAX_TOOL_CALL_ROUNDS
      rounds += 1

      tool_calls = function_tool_caller.fulfill_requests(response.function_requests)
      executed_tool_calls.concat(tool_calls)

      # Record every tool call made this turn on the assistant message.
      emit(:response, { id: response.id, function_tool_calls: executed_tool_calls })

      # Feed this round's results back. Per-step (not accumulated): the native
      # Responses API chains prior turns via previous_response_id and would
      # reject re-submitted outputs; the generic path gets the triggering result.
      response = get_llm_response(
        streamer: text_streamer,
        function_results: tool_calls.map(&:to_result),
        previous_response_id: response.id
      )
    end

    # Never leave a blank, pending turn: the chat watchdog would later report it
    # as "the assistant didn't respond". If the model produced no text (it wanted
    # to keep calling tools past the cap, or returned nothing), surface a message.
    emit(:output_text, no_answer_message) unless @text_emitted

    emit(:response, { id: response.id })
  end

  private
    attr_reader :message, :instructions, :function_tool_caller, :llm

    # Streams assistant text to listeners and records that a turn produced text,
    # so we can guarantee a non-blank response. Ignores "response" chunks — the
    # loop in #respond uses each call's return value for control flow.
    def text_streamer
      proc do |chunk|
        next unless chunk.type == "output_text"

        @text_emitted = true
        emit(:output_text, chunk.data)
      end
    end

    def no_answer_message
      I18n.t(
        "assistant.responder.no_answer",
        default: "I wasn't able to finish answering that in a single turn — it needed more steps than I can take at once. Please try a narrower question or ask me to continue."
      )
    end

    def get_llm_response(streamer:, function_results: [], previous_response_id: nil)
      response = llm.chat_response(
        message.content,
        model: message.ai_model,
        instructions: instructions,
        functions: function_tool_caller.function_definitions,
        function_results: function_results,
        messages: openai_messages_payload,
        conversation_history: chat_message_records,
        streamer: streamer,
        previous_response_id: previous_response_id,
        session_id: chat_session_id,
        user_identifier: chat_user_identifier,
        family: message.chat&.user&.family
      )

      unless response.success?
        raise response.error
      end

      response.data
    end

    def emit(event_name, payload = nil)
      listeners[event_name.to_sym].each { |block| block.call(payload) }
    end

    def listeners
      @listeners ||= Hash.new { |h, k| h[k] = [] }
    end

    def chat_session_id
      chat&.id&.to_s
    end

    def chat_user_identifier
      return unless chat&.user_id

      ::Digest::SHA256.hexdigest(chat.user_id.to_s)
    end

    def chat
      @chat ||= message.chat
    end

    # Memoized fetch — both `chat_message_records` and `openai_messages_payload`
    # derive their shape from this one in-memory array so a single chat turn
    # fires one history query instead of two.
    def complete_chat_messages
      return @complete_chat_messages if defined?(@complete_chat_messages)

      @complete_chat_messages =
        if chat&.messages
          chat.messages
              .where(type: [ "UserMessage", "AssistantMessage" ], status: "complete")
              .includes(:tool_calls)
              .ordered
              .to_a
        else
          []
        end
    end

    # Raw Message records preceding the current turn — providers that build
    # their own native message shape (Anthropic) consume this directly so they
    # do not have to round-trip through the OpenAI-shaped payload below.
    def chat_message_records
      complete_chat_messages.reject { |m| m.id == message.id }
    end

    # Builds the OpenAI-shaped messages payload (role: "user" | "assistant" |
    # "tool"; tool_call_id pairing) consumed by Provider::Openai's generic
    # chat path. Anthropic uses chat_message_records instead.
    def openai_messages_payload
      messages = []
      complete_chat_messages.each do |chat_message|
        if chat_message.tool_calls.any?
          messages << {
            role: chat_message.role,
            content: chat_message.content || "",
            tool_calls: chat_message.tool_calls.map(&:to_tool_call)
          }

          chat_message.tool_calls.map(&:to_result).each do |fn_result|
            # Handle nil explicitly to avoid serializing to "null"
            output = fn_result[:output]
            content = if output.nil?
              ""
            elsif output.is_a?(String)
              output
            else
              output.to_json
            end

            messages << {
              role: "tool",
              tool_call_id: fn_result[:call_id],
              name: fn_result[:name],
              content: content
            }
          end

        elsif !chat_message.content.blank?
          messages << { role: chat_message.role, content: chat_message.content || "" }
        end
      end
      messages
    end
end
