require "../spec_helper"
require "../../src/punch/mail/carbon"

module CarbonSpec
  struct Credentials
    include Punch::Credentials

    getter mail : Punch::Mailer::Settings
  end

  SETTINGS = <<-YAML
    mail:
      delivery: capture
      from: billing@example.org
      from_name: Example Billing
    YAML

  struct Notice
    include Punch::Mail

    def to : Punch::Mail::Address
      Punch::Mail::Address.new(Punch::Email.parse("ada@example.org").as(Punch::Email), "Ada Lovelace, CEO")
    end

    def reply_to : Punch::Mail::Address?
      Punch::Mail::Address.new(Punch::Email.parse("support@example.org").as(Punch::Email))
    end

    def subject(locale : Punch::Locale) : String
      "Hello"
    end

    def view(v : Punch::View) : Nil
      v.p "Dear Ada"
    end
  end

  # What a provider's adapter is: it takes a `Carbon::Email`.
  class Provider < Carbon::Adapter
    # ameba:disable Punch/MailDelivery
    getter emails = [] of Carbon::Email

    def initialize(@failure : Exception? = nil)
    end

    # ameba:disable Punch/MailDelivery
    def deliver_now(email : Carbon::Email)
      @failure.try { |failure| raise failure }
      @emails << email
    end
  end
end

describe Punch::Mailer::CarbonAdapter do
  before_each { Punch::Spec.credentials(CarbonSpec::Credentials, CarbonSpec::SETTINGS) }

  it "hands a Carbon adapter the rendered mail" do
    provider = CarbonSpec::Provider.new
    Punch::Mailer.deliver_with(Punch::Mailer::CarbonAdapter.new(provider), CarbonSpec::Notice.new, Punch::I18n.default, "k").should be_nil
    email = provider.emails.first
    email.subject.should eq("Hello")
    email.from.should eq(Carbon::Address.new("Example Billing", "billing@example.org"))
    email.to.map(&.address).should eq(["ada@example.org"])
    email.to.first.name.to_s.should start_with("=?UTF-8?B?")
    email.headers["Reply-To"].should eq("support@example.org")
    email.text_body.to_s.should contain("Dear Ada")
    email.html_body.to_s.should contain("<p>Dear Ada</p>")
  end

  it "retries when the Carbon adapter raises" do
    adapter = Punch::Mailer::CarbonAdapter.new(CarbonSpec::Provider.new(IO::Error.new("reset")))
    Punch::Mailer.deliver_with(adapter, CarbonSpec::Notice.new, Punch::I18n.default, "k").should be_a(Punch::Job::Retry)
  end
end
