require "carbon"
require "../../punch"

module Punch::Mailer
  # Runs a Carbon provider adapter as a Punch adapter. Punch does not
  # depend on Carbon: an app that wants such an adapter adds `carbon` and
  # the adapter's shard, and requires this file.
  #
  # ```
  # require "punch/mail/carbon"
  #
  # Punch::Mailer.adapter do
  #   Punch::Mailer::CarbonAdapter.new(Carbon::SendGridAdapter.new(api_key: Invoicing::Credentials.current.sendgrid.api_key.unwrap))
  # end
  # ```
  class CarbonAdapter < Adapter
    def initialize(@adapter : Carbon::Adapter)
    end

    def deliver_now(message : Message) : Nil
      @adapter.deliver_now(CarbonEmail.new(message))
      nil
    end
  end

  # A rendered mail in the shape a Carbon adapter takes.
  # :nodoc:
  class CarbonEmail < Carbon::Email
    getter subject : String
    getter from : Carbon::Address
    getter to : Array(Carbon::Address)
    getter text_body : String
    getter html_body : String

    def initialize(message : Message)
      @subject = message.subject
      @from = CarbonEmail.address(message.from)
      @to = message.to.map { |address| CarbonEmail.address(address) }
      @text_body = message.text
      @html_body = message.html.value
      message.reply_to.try { |address| @headers["Reply-To"] = address.to_s }
    end

    def self.address(address : Mail::Address) : Carbon::Address
      name = address.header_name
      name ? Carbon::Address.new(name, address.email.value) : Carbon::Address.new(address.email.value)
    end
  end
end
