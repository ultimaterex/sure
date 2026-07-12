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

  # Maps the Interactions API `usage` object (total_input_tokens /
  # total_output_tokens / total_cached_tokens / total_thought_tokens /
  # total_tokens) to the same internal shape as #from_metadata.
  def from_interaction(usage)
    return {} unless usage

    u = usage.is_a?(Hash) ? usage.with_indifferent_access : {}

    prompt = u[:total_input_tokens].to_i
    completion = u[:total_output_tokens].to_i
    total = u[:total_tokens].to_i
    total = prompt + completion if total.zero?

    hash = {
      "input_tokens" => prompt,
      "output_tokens" => completion,
      "total_tokens" => total
    }
    hash["cache_read_input_tokens"] = u[:total_cached_tokens].to_i if u.key?(:total_cached_tokens)
    hash["thoughts_tokens"] = u[:total_thought_tokens].to_i if u.key?(:total_thought_tokens)
    hash
  end
end
