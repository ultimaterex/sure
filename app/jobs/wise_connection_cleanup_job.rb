# frozen_string_literal: true

class WiseConnectionCleanupJob < ApplicationJob
  queue_as :default

  def perform(wise_item_id:, account_id:)
    Rails.logger.info(
      "WiseConnectionCleanupJob - Cleaning up for former account #{account_id}"
    )

    wise_item = WiseItem.find_by(id: wise_item_id)
    return unless wise_item

    # For banking providers, cleanup is typically simpler since there's no
    # separate authorization concept - the item itself holds the credentials.
    # Override this method if your provider needs specific cleanup logic.

    Rails.logger.info("WiseConnectionCleanupJob - Cleanup complete for account #{account_id}")
  rescue => e
    Rails.logger.warn(
      "WiseConnectionCleanupJob - Failed: #{e.class} - #{e.message}"
    )
    # Don't raise - cleanup failures shouldn't block other operations
  end
end
