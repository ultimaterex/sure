# frozen_string_literal: true

# Maps Gemini's usageMetadata to the internal usage hash shape (input_tokens /
# output_tokens / total_tokens, plus cache + thinking token counts).
module Provider::Gemini::Usage
  module_function

  def from_metadata(metadata)
    return {} unless metadata

    md = metadata.is_a?(Hash) ? metadata.with_indifferent_access : {}

    prompt = md[:promptTokenCount].to_i
    completion = md[:candidatesTokenCount].to_i
    total = md[:totalTokenCount].to_i
    total = prompt + completion if total.zero?

    hash = {
      "input_tokens" => prompt,
      "output_tokens" => completion,
      "total_tokens" => total
    }
    hash["cache_read_input_tokens"] = md[:cachedContentTokenCount].to_i if md.key?(:cachedContentTokenCount)
    hash["thoughts_tokens"] = md[:thoughtsTokenCount].to_i if md.key?(:thoughtsTokenCount)
    hash
  end
end
