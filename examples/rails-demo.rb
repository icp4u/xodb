# Rails-flavoured xodb demo: ActiveModel orders checked out in a loop.
# Needs activemodel (and activesupport) on GEM_PATH; scripts/demo-rails sets it
# from XODB_RAILS_GEMS.
# The loop stops in Integer#digits (rb_int_digits), called by the Luhn
# validation inside ActiveModel::Validations#valid?.
require "active_support/all"
require "active_model"

# A Concern, as in app/models/concerns.
module Auditable
  extend ActiveSupport::Concern

  included do
    attribute :audited_at, :datetime
    validate :number_passes_luhn
  end

  class_methods do
    def audit_label = name.underscore.humanize
  end

  def stamp! = self.audited_at = Time.current

  private

  # Luhn checksum on the order number: the demo's stopping point.
  def number_passes_luhn
    digits = number.delete("^0-9").to_i.digits
    sum = digits.each_with_index.sum { |d, i| i.odd? ? (d * 2).divmod(10).sum : d }
    errors.add(:number, "fails its checksum") unless (sum % 10).zero?
  end
end

class LineItem
  include ActiveModel::Model
  include ActiveModel::Attributes

  attribute :sku, :string
  attribute :price_cents, :integer
  attribute :quantity, :integer, default: 1

  validates :sku, presence: true
  validates :quantity, numericality: { greater_than: 0 }

  def total_cents = price_cents * quantity
  def to_h = { sku: sku, price: price_cents, qty: quantity }
end

class Order
  include ActiveModel::Model
  include ActiveModel::Attributes
  include ActiveModel::Dirty
  include Auditable

  STATUSES = %w[cart pending paid].freeze

  attribute :number, :string
  attribute :status, :string, default: "cart"
  attribute :placed_at, :datetime

  attr_accessor :line_items

  validates :number, presence: true
  validates :status, inclusion: { in: STATUSES }

  def checkout!(round)
    items = line_items.select(&:valid?)
    total = items.sum(&:total_cents)
    attrs = {
      number: number,
      status: :pending,
      total_cents: total,
      line_items: items.map(&:to_h),
    }
    params = attrs.with_indifferent_access
    batches = items.map(&:sku).in_groups_of(2, false)
    ActiveSupport::Notifications.instrument("checkout.orders", number: number, total: total) do
      self.status = "pending"
      self.placed_at = 2.days.ago
      stamp!
      if valid?
        changes_applied
        self.status = "paid"
      end
    end
    [errors.full_messages, attrs, params, batches]
  end
end

checkouts = Hash.new(0)
ActiveSupport::Notifications.subscribe("checkout.orders") do |event|
  checkouts[event.payload[:number]] += 1
end

table = "line_item".camelize.underscore.pluralize # "line_items"
coupon = "".presence || "WELCOME10"
skus = %w[ruby-mug rails-tee gem-sticker]

$stdout.sync = true
puts Process.pid
round = 0
# The last checkout's results live in <main>, so they survive each stop.
errors = attrs = params = batches = nil
loop do
  # Every fifth order number breaks the Luhn checksum.
  number = round % 5 == 4 ? "R-79927398710" : "R-79927398713"
  items = skus.each_with_index.map do |sku, i|
    LineItem.new(sku: sku, price_cents: 1299 + 100 * ((round + i) % 7), quantity: 1 + round % 3)
  end
  order = Order.new(number: number, line_items: items)
  errors, attrs, params, batches = order.checkout!(round)
  round += 1
end
