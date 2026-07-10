module Family::WiseConnectable
  extend ActiveSupport::Concern

  included do
    has_many :wise_items, dependent: :destroy
  end

  def can_connect_wise?
    # Families can configure their own Wise credentials
    true
  end

  def create_wise_item!(api_token:, base_url: nil, item_name: nil)
    wise_item = wise_items.create!(
      name: item_name || "Wise Connection",
      api_token: api_token,
      base_url: base_url
    )

    wise_item.sync_later

    wise_item
  end

  def has_wise_credentials?
    wise_items.where.not(api_token: nil).exists?
  end
end
