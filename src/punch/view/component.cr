module Punch
  # Something a view can render: a page's content, a layout, a partial
  # (they are all components). A component is a plain struct or class with
  # typed constructor arguments and a `view` method that writes to the view
  # it is given:
  #
  # ```
  # struct InvoiceSummary
  #   include Punch::Component
  #
  #   def initialize(@invoice : Invoices::Detail)
  #   end
  #
  #   def view(v : Punch::View) : Nil
  #     v.p do
  #       v.text "Total: "
  #       v.strong @invoice.total.to_s
  #     end
  #   end
  # end
  # ```
  #
  # A layout takes the content as a block: `def view(v : Punch::View, &) : Nil`,
  # rendered with `v.render(Layout.new(title)) { ... }`.
  #
  # Take `v : Punch::View`. A component that needs markup the elements
  # cannot express takes `v : Punch::HTMLView`, which has `raw`, and says
  # so: pages that agents read render through a plain `View`, where such a
  # component does not compile.
  module Component
  end
end
