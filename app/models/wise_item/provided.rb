# frozen_string_literal: true

module WiseItem::Provided
  extend ActiveSupport::Concern

  def wise_provider
    return nil unless credentials_configured?

    Provider::Wise.new(
      api_token: api_token.to_s.strip,
      base_url: effective_base_url
    )
  end

  # Returns credentials hash for API calls that need them passed explicitly
  def wise_credentials
    return nil unless credentials_configured?

    {
      api_token: api_token
    }
  end
end
