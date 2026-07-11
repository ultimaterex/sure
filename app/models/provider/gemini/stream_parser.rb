# frozen_string_literal: true

# Incrementally parses a Gemini `streamGenerateContent?alt=sse` response body.
# Feed raw HTTP body fragments via #push; it buffers, splits on SSE event
# boundaries (blank line), and yields each decoded JSON chunk. Non-data lines
# (comments, event:) and the sentinel `[DONE]` are ignored.
class Provider::Gemini::StreamParser
  def initialize
    @buffer = +""
  end

  def push(fragment)
    @buffer << fragment.to_s

    while (boundary = @buffer.index("\n\n"))
      raw_event = @buffer.slice!(0, boundary + 2)
      json = decode(raw_event)
      yield json if json
    end
  end

  private

    def decode(raw_event)
      payload = raw_event.each_line.filter_map do |line|
        line = line.chomp
        next if line.empty? || line.start_with?(":")
        next unless line.start_with?("data:")

        line.sub(/\Adata:\s?/, "")
      end.join

      return nil if payload.empty? || payload == "[DONE]"

      JSON.parse(payload)
    rescue JSON::ParserError
      nil
    end
end
