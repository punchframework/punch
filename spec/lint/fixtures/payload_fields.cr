# Fixture for Punch/PayloadFields: collections in job and event payloads.
module Billing
  record InvoicesSent,
    invoice_ids : Array(Invoices::ID), # expect
    customer_id : Customers::ID do
    include Punch::Event
  end

  record Remind,
    invoice_id : Invoices::ID,
    note : String? = nil,
    totals : Hash(String, Int64) = {} of String => Int64, # expect
    raw : JSON::Any? = nil do                             # expect
    include Punch::Job
  end

  struct Export
    include Punch::Job::Stepped

    getter customer_id : Customers::ID
    getter rows : Bytes                    # expect
    getter pair : {Int64, String}          # expect
    @extra : Punch::Secret(Array(String))? # expect
  end

  # Not a payload.
  record Summary, ids : Array(Int64)

  struct Report
    getter lines : Array(String)
  end
end
