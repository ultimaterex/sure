# frozen_string_literal: true

require "digest"

# Manages Gemini explicit context caching. The assistant sends the same large
# system instruction + tool schemas on every turn; caching that stable prefix
# once and referencing it via `cachedContent` cuts the per-request input cost.
#
# Opt-in (GEMINI_CONTEXT_CACHE) and strictly best-effort: any failure — caching
# disabled, content below Gemini's minimum token size, a transient API error —
# returns nil so the caller sends the content inline as usual. It can never
# break a chat request.
class Provider::Gemini::ContextCache
  def initialize(client)
    @client = client
  end

  # Returns a cachedContent `name` for this model + system + tools, creating one
  # if needed, or nil when caching is unavailable (caller then inlines).
  def fetch(model:, system_instruction:, tools:)
    return nil unless enabled?
    return nil if system_instruction.blank? && tools.blank?

    key = cache_key(model, system_instruction, tools)
    cached = Rails.cache.read(key)
    return cached if cached.present?

    name = @client.create_cached_content(
      model: model,
      system_instruction: system_instruction,
      tools: tools,
      ttl_seconds: ttl_seconds
    )

    # Expire our record slightly before the server-side cache so we never
    # reference a cache Gemini has already dropped.
    Rails.cache.write(key, name, expires_in: [ ttl_seconds - 60, 60 ].max) if name.present?
    name
  rescue Provider::Gemini::Error => e
    Rails.logger.warn("Gemini context cache unavailable, sending inline: #{e.message}")
    nil
  end

  private

    def enabled?
      # GEMINI_CONTEXT_CACHE env wins (and locks the UI toggle); otherwise the
      # Setting toggle, default off.
      Provider::Gemini.flag_enabled?("GEMINI_CONTEXT_CACHE", Setting.gemini_context_cache)
    end

    def ttl_seconds
      ENV.fetch("GEMINI_CONTEXT_CACHE_TTL", 3600).to_i
    end

    def cache_key(model, system_instruction, tools)
      digest = Digest::SHA256.hexdigest([ model, system_instruction, tools ].to_json)
      "gemini_context_cache/#{digest}"
    end
end
