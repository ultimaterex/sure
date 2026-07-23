module Assistant::Provided
  extend ActiveSupport::Concern

  def get_model_provider(ai_model)
    supporting = registry.providers.select { |provider| provider.supports_model?(ai_model) }

    # A custom OpenAI-compatible provider claims every model, so it would hijack
    # models meant for another provider. When the user has picked an LLM provider,
    # prefer it among the ones that support the model.
    preferred_class = PREFERRED_PROVIDER_CLASSES[Setting.llm_provider.to_s]
    (preferred_class && supporting.find { |provider| provider.instance_of?(preferred_class) }) || supporting.first
  end

  private
    PREFERRED_PROVIDER_CLASSES = {
      "openai" => Provider::Openai,
      "anthropic" => Provider::Anthropic,
      "gemini" => Provider::Gemini
    }.freeze

    def registry
      @registry ||= Provider::Registry.for_concept(:llm)
    end
end
