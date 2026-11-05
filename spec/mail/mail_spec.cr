require "../spec_helper"

module MailSpec
  struct Credentials
    include Punch::Credentials

    getter mail : Punch::Mailer::Settings
  end

  # An adapter for a provider's API: records what it gets, and fails with
  # the exception it is given.
  class ProviderAdapter < Punch::Mailer::Adapter
    getter messages = [] of Punch::Mailer::Message

    def initialize(@failure : Exception? = nil)
    end

    def deliver_now(message : Punch::Mailer::Message) : Nil
      @failure.try { |failure| raise failure }
      @messages << message
    end
  end

  SETTINGS = <<-YAML
    mail:
      delivery: capture
      from: billing@example.org
      from_name: Example Billing
    YAML

  def self.email(text : String) : Punch::Email
    Punch::Email.parse(text).as(Punch::Email)
  end

  # A link to one of the app's pages, as `SomePage.href` makes it.
  def self.page(path : String) : Punch::Href
    Punch::Href.new(path, "MailSpec::Page")
  end

  struct Notice
    include Punch::Mail

    def initialize(@name : String, @to : String = "ada@example.org")
    end

    def to : Punch::Mail::Address
      Punch::Mail::Address.new(MailSpec.email(@to), @name)
    end

    def subject(locale : Punch::Locale) : String
      "Invoice for #{@name} (#{locale.code})"
    end

    def reply_to : Punch::Mail::Address?
      Punch::Mail::Address.new(MailSpec.email("support@example.org"))
    end

    def view(v : Punch::View) : Nil
      v.chrome { |chrome| chrome.nav { chrome.text "navigation" } }
      v.h1 "Invoice A-1"
      v.p do
        v.text "Dear #{@name},\n   your   invoice"
        v.br
        v.text "is "
        v.strong "due"
        v.text ": "
        v.a "open it", href: MailSpec.page("/invoices/1")
      end
      v.p { v.a "https://example.org/terms", href: Punch::Href.external("https://example.org/terms") }
      v.ol do
        v.li "first"
        v.li do
          v.p "second"
          v.ul { v.li "nested" }
        end
      end
      v.table do
        v.caption "Lines"
        v.thead { v.tr { v.th "Item"; v.th "Amount" } }
        v.tbody do
          v.tr { v.td "Consulting"; v.td v.locale.money(Punch::Money.parse(25_000).as(Punch::Money), Punch::Currency.parse("EUR").as(Punch::Currency)) }
          v.tr { v.td "Travel"; v.td "12" }
        end
      end
      v.blockquote { v.p "Thank you" }
      v.dl { v.dt "Due"; v.dd "in 14 days" }
      v.hr
      v.pre "  kept\n    as is"
      v.p { v.img src: MailSpec.page("/logo.png"), alt: "Example" }
    end
  end

  # A mail whose view is a block, for examples about single elements.
  struct Block
    include Punch::Mail

    def initialize(&@block : Punch::View ->)
    end

    def to : Punch::Mail::Address
      Punch::Mail::Address.new(MailSpec.email("ada@example.org"))
    end

    def subject(locale : Punch::Locale) : String
      "block"
    end

    def view(v : Punch::View) : Nil
      @block.call(v)
    end
  end

  def self.text(&block : Punch::View ->) : String
    Punch::Spec.render_mail(Block.new(&block)).text
  end

  # Every element a mail may hold, each around its own word, inside the
  # parents it needs.
  def self.every_element(v : Punch::View) : Nil
    {% for name, model in Punch::View::ELEMENTS %}
      {% if model[0] == :phrasing && model[1] == :phrasing && name != :a %}
        v.p { v.{{ name.id }} { v.text "zz{{ name.id }}" } }
      {% elsif model[0] == :flow && model[1] != :none && model[1] != :list && model[1] != :terms && model[1] != :table && model[1] != :details %}
        v.{{ name.id }} { v.text "zz{{ name.id }}" }
      {% end %}
    {% end %}
    v.p { v.a "zza", href: MailSpec.page("/") }
    v.p { v.img src: MailSpec.page("/logo.png"), alt: "zzimg" }
    v.ul { v.li "zzli" }
    v.ol { v.li "zzol" }
    v.dl { v.dt "zzdt"; v.dd "zzdd" }
    v.details { v.summary "zzsummary"; v.p "zzdetails" }
    v.fieldset { v.legend "zzlegend"; v.p "zzfieldset" }
    v.table do
      v.caption "zzcaption"
      v.thead { v.tr { v.th "zzth" } }
      v.tbody { v.tr { v.td "zztd" } }
      v.tfoot { v.tr { v.td "zztfoot" } }
    end
  end

  struct WithForm
    include Punch::Mail

    def to : Punch::Mail::Address
      Punch::Mail::Address.new(MailSpec.email("ada@example.org"))
    end

    def subject(locale : Punch::Locale) : String
      "form"
    end

    def view(v : Punch::View) : Nil
      v.document("x") { v.p "x" }
    end
  end

  struct Notify
    include Punch::Job

    getter name : String
    getter to : String

    def initialize(@name, @to = "ada@example.org")
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
      Punch::Mailer.deliver(Notice.new(name, to), locale: Punch::I18n.locale("de"), job: job)
    end
  end

  # An SMTP server for one example: accepts everything except recipients
  # starting with `reject@` (550) or `later@` (451), refuses STARTTLS, and
  # keeps what DATA received.
  class FakeSMTP
    getter port : Int32
    getter data = Channel(String).new(10)

    def initialize
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.local_address.port
      spawn { serve }
    end

    def close : Nil
      @server.close
    end

    private def serve : Nil
      while socket = @server.accept?
        spawn session(socket)
      end
    end

    private def session(socket : TCPSocket) : Nil
      reply(socket, "220 fake ESMTP")
      while line = socket.gets(chomp: true)
        case line
        when /\AEHLO/i             then reply(socket, "250-fake\r\n250 STARTTLS")
        when /\ASTARTTLS/i         then reply(socket, "454 TLS not available")
        when /\ARCPT TO:<reject@/i then reply(socket, "550 5.1.1 No such user")
        when /\ARCPT TO:<later@/i  then reply(socket, "451 4.3.0 Try again later")
        when /\ADATA/i
          reply(socket, "354 go on")
          body = String.build do |io|
            while (part = socket.gets(chomp: false)) && part != ".\r\n"
              io << part
            end
          end
          @data.send(body)
          reply(socket, "250 queued")
        when /\AQUIT/i
          reply(socket, "221 bye")
          break
        else reply(socket, "250 OK")
        end
      end
    rescue IO::Error
    ensure
      socket.close
    end

    private def reply(socket : TCPSocket, text : String) : Nil
      socket << text << "\r\n"
      socket.flush
    end
  end

  def self.smtp(port : Int32, tls = Punch::Mailer::TLS::Plain) : Punch::Mailer::SMTP
    Punch::Mailer::SMTP.new("127.0.0.1", port, tls, nil, nil)
  end
end

describe Punch::Mailer do
  # Other specs load other settings into the same process.
  before_each { Punch::Spec.credentials(MailSpec::Credentials, MailSpec::SETTINGS) }

  describe ".render" do
    it "writes the text part as plain text: structure without markup, links absolute, nothing escaped" do
      rendered = Punch::Spec.render_mail(MailSpec::Notice.new("Ada <script>"), Punch::I18n.locale("en"))
      rendered.subject.should eq("Invoice for Ada <script> (en)")
      rendered.text.should eq(<<-TEXT + "\n")
        Invoice A-1
        ===========

        Dear Ada <script>, your invoice
        is *due*: open it <#{Punch.public_url}/invoices/1>

        https://example.org/terms

        1. first
        2. second

           - nested

        Lines
        Item        Amount
        ----------  -------
        Consulting  €250.00
        Travel      12

        > Thank you

        Due
          in 14 days

        ----------

          kept
            as is

        Example
        TEXT
    end

    it "marks emphasis, deleted text, and quotations in the text part, as plain-text mail does" do
      MailSpec.text do |v|
        v.p do
          v.text "Pay "
          v.del "€300"
          v.text " "
          v.s " €280 "
          v.text " "
          v.strong { v.text "€250"; v.text " " }
          v.text "by "
          v.em "Friday"
          v.text ", "
          v.b { v.i "really" }
          v.text ". "
          v.q "Thanks"
          v.strong ""
          v.text "*kept*"
        end
      end.should eq("Pay ~~€300~~ ~~€280~~ *€250* by _Friday_, *_really_*. “Thanks”*kept*\n")
    end

    it "keeps the text of every element the markdown backend shows" do
      markdown = Punch::Spec.markdown(MailSpec::Block.new { |v| MailSpec.every_element(v) })
      text = MailSpec.text { |v| MailSpec.every_element(v) }
      words = markdown.scan(/zz[a-z0-9]+/).map(&.[0])
      words.size.should be > 50
      words.reject { |word| text.includes?(word) }.should be_empty
    end

    it "writes the HTML part as a whole document with absolute links, escaped, without chrome" do
      html = Punch::Spec.render_mail(MailSpec::Notice.new("Ada <script>"), Punch::I18n.locale("de")).html.value
      html.should start_with("<!doctype html>\n<html lang=\"de\">")
      html.should contain("<title>Invoice for Ada &lt;script&gt; (de)</title>")
      html.should contain(%(<a href="#{Punch.public_url}/invoices/1">open it</a>))
      html.should contain(%(<img src="#{Punch.public_url}/logo.png" alt="Example">))
      html.should contain("Dear Ada &lt;script&gt;")
      html.should_not contain("navigation")
      html.should contain("250,00 €")
    end

    it "refuses a document or a form inside a mail" do
      expect_raises(Punch::View::NestingError, /a mail has no document/) do
        Punch::Spec.render_mail(MailSpec::WithForm.new)
      end
    end

    it "keeps control characters out of names and the subject" do
      address = Punch::Mail::Address.new(MailSpec.email("ada@example.org"), "Ada\r\nBcc: eve@example.org")
      # Characters that mean something in an address go encoded.
      address.to_s.should eq(%("=?UTF-8?B?QWRhIEJjYzogZXZlQGV4YW1wbGUub3Jn?=" <ada@example.org>))
      Punch::Mail::Address.new(MailSpec.email("ada@example.org"), %(Ada", eve@example.org <x)).header_name.to_s.should start_with("=?UTF-8?B?")
      Punch::Mail::Address.new(MailSpec.email("ada@example.org"), "Ada Lovelace").header_name.should eq("Ada Lovelace")
      Punch::Mail::Address.new(MailSpec.email("ada@example.org"), " \n").name.should be_nil
    end
  end

  describe ".deliver" do
    it "delivers from a job in the recipient's locale, with the job's key, from the configured sender" do
      Punch::Spec.queue.enqueue(MailSpec::Notify.new("Ada"))
      -> { Punch::Spec.perform_jobs.map(&.outcome.to_s).should eq(["Done"]) }.should deliver_mail(MailSpec::Notice, to: "ada@example.org", times: 1)
      mail = Punch::Spec.mails(to: "ada@example.org").first
      mail.subject.should eq("Invoice for Ada (de)")
      mail.locale.should eq("de")
      mail.from.should eq(%("Example Billing" <billing@example.org>))
      mail.to.should eq([%("Ada" <ada@example.org>)])
      mail.reply_to.should eq("support@example.org")
      mail.key.should_not be_empty
      mail.paths.should eq(["/invoices/1"])
      mail.links.should contain("https://example.org/terms")
      mail.html.value.should contain("<h1>Invoice A-1</h1>")
    end

    it "keeps each example's mails apart" do
      Punch::Spec.mails.should be_empty
      -> { }.should_not deliver_mail(MailSpec::Notice)
    end

    it "records a span without addresses" do
      spans = Punch::Spec.trace do
        Punch::Mailer.deliver_with(Punch::Spec::MAILS, MailSpec::Notice.new("Ada"), Punch::I18n.default, "k1")
      end
      spans.should have_span("mail.deliver", "punch.mail.type": "MailSpec::Notice", "punch.mail.key": "k1", "punch.mail.recipients": 1)
    end

    it "refuses to deliver inside a write transaction" do
      Punch::Spec.queue.enqueue(MailSpec::Notify.new("Ada"))
      Punch::Spec.db.write do |_db|
        expect_raises(ArgumentError, /inside a write transaction/) do
          Punch::Mailer.deliver(MailSpec::Notice.new("Ada"), locale: Punch::I18n.default,
            job: Punch::Job::Context.new(Punch::Spec.db, Punch::Spec.queue, 1, 1, 1, "default", "k"))
        end
      end
    end
  end

  describe Punch::Mailer::Adapter do
    it "gets the rendered mail, with the job's key and the plain name" do
      adapter = MailSpec::ProviderAdapter.new
      Punch::Mailer.deliver_with(adapter, MailSpec::Notice.new("Ada"), Punch::I18n.default, "k1").should be_nil
      message = adapter.messages.first
      message.key.should eq("k1")
      message.type.should eq("MailSpec::Notice")
      message.from.name.should eq("Example Billing")
      message.to.map(&.email.value).should eq(["ada@example.org"])
      message.html.value.should contain("<h1>Invoice A-1</h1>")
    end

    it "turns a delivery failure into the job's result" do
      deliver = ->(failure : Exception) do
        Punch::Mailer.deliver_with(MailSpec::ProviderAdapter.new(failure), MailSpec::Notice.new("Ada"), Punch::I18n.default, "k")
      end
      deliver.call(Punch::Mailer::DeliveryFailed.new("gone", permanent: true)).should be_a(Punch::Job::Discard)
      deliver.call(Punch::Mailer::DeliveryFailed.new("busy")).should be_a(Punch::Job::Retry)
      deliver.call(IO::Error.new("reset")).should be_a(Punch::Job::Retry)
    end
  end

  describe Punch::Mailer::SMTP do
    it "sends a multipart message and answers nil" do
      server = MailSpec::FakeSMTP.new
      begin
        result = Punch::Mailer.deliver_with(MailSpec.smtp(server.port), MailSpec::Notice.new("Ada"), Punch::I18n.default, "k1")
        result.should be_nil
        data = server.data.receive
        data.should contain("multipart/alternative")
        data.should contain("Reply-To: support@example.org")
        data.should match(/^To: .*ada@example\.org/m)
      ensure
        server.close
      end
    end

    it "discards a mail whose recipient the server refuses for good, and retries a temporary refusal" do
      server = MailSpec::FakeSMTP.new
      begin
        rejected = Punch::Mailer.deliver_with(MailSpec.smtp(server.port), MailSpec::Notice.new("Ada", "reject@example.org"), Punch::I18n.default, "k")
        rejected.should be_a(Punch::Job::Discard)
        rejected.as(Punch::Job::Discard).reason.should eq("SMTP RCPT refused: 550 5.1.1 No such user")
        later = Punch::Mailer.deliver_with(MailSpec.smtp(server.port), MailSpec::Notice.new("Ada", "later@example.org"), Punch::I18n.default, "k")
        later.as(Punch::Job::Retry).reason.should eq("SMTP RCPT refused: 451 4.3.0 Try again later")
      ensure
        server.close
      end
    end

    it "never falls back to plain text when STARTTLS is refused" do
      server = MailSpec::FakeSMTP.new
      begin
        result = Punch::Mailer.deliver_with(MailSpec.smtp(server.port, Punch::Mailer::TLS::Starttls), MailSpec::Notice.new("Ada"), Punch::I18n.default, "k")
        result.as(Punch::Job::Retry).reason.should contain("could not be set up")
        select
        when server.data.receive then fail "a message was sent without TLS"
        else
        end
      ensure
        server.close
      end
    end

    it "retries when nothing listens" do
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.port
      server.close
      result = Punch::Mailer.deliver_with(MailSpec.smtp(port), MailSpec::Notice.new("Ada"), Punch::I18n.default, "k")
      result.as(Punch::Job::Retry).reason.should start_with("SMTP 127.0.0.1:#{port}:")
    end
  end

  describe ".configure" do
    it "reports settings that do not fit together" do
      source = Punch::Credentials::Source.new("test", ->(_name : String) { nil.as(String?) },
        Punch::Credentials::YAMLTree.parse("mail:\n  delivery: smtp\n  from: a@example.org\n", "spec").as(Hash), "spec")
      settings = MailSpec::Credentials.load(source).as(MailSpec::Credentials).mail
      Punch::Mailer.configure(settings)
      Punch::Mailer.problems.should eq(["mail.smtp.host (MAIL__SMTP__HOST) must be set when mail.delivery is smtp"])
    end

    it "refuses captured mail and a password over plain SMTP outside development and test" do
      load = ->(yaml : String) {
        source = Punch::Credentials::Source.new("production", ->(_name : String) { nil.as(String?) }, Punch::Credentials::YAMLTree.parse(yaml, "spec").as(Hash), "spec")
        Punch::Mailer.configure(MailSpec::Credentials.load(source).as(MailSpec::Credentials).mail)
      }
      load.call("mail:\n  delivery: capture\n  from: a@example.org\n")
      Punch::Mailer.environment_problems("production").first.should contain("no mail would leave")
      Punch::Mailer.environment_problems("test").should be_empty
      load.call("mail:\n  delivery: smtp\n  from: a@example.org\n  smtp:\n    host: mail.example.org\n    tls: plain\n    username: u\n    password: p\n")
      Punch::Mailer.environment_problems("production").should eq(["mail.smtp.tls is plain with a password, to mail.example.org: use starttls or smtps"])
    ensure
      Punch::Mailer.configure(MailSpec::Credentials.load(Punch::Credentials::Source.new("test", ->(_name : String) { nil.as(String?) },
        Punch::Credentials::YAMLTree.parse(MailSpec::SETTINGS, "spec").as(Hash), "spec")).as(MailSpec::Credentials).mail)
    end
  end
end

describe Punch::AppConfig do
  it "takes the public URL from PUNCH_PUBLIC_URL, required outside development and test" do
    Punch::AppConfig.from({"PUNCH_PUBLIC_URL" => "https://invoices.example.org/"}).as(Punch::AppConfig).public_url.should eq("https://invoices.example.org")
    Punch::AppConfig.from({"PUNCH_PORT" => "8080"}).as(Punch::AppConfig).public_url.should eq("http://127.0.0.1:8080")
    Punch::AppConfig.from({"PUNCH_ENV" => "production"}).as(Array(String)).first.should start_with("PUNCH_PUBLIC_URL must be set in production")
    Punch::AppConfig.from({"PUNCH_PUBLIC_URL" => "ftp://x.org"}).as(Array(String)).first.should start_with("PUNCH_PUBLIC_URL must be an http or https URL")
    Punch::AppConfig.from({"PUNCH_PUBLIC_URL" => "https://x.org/?a=1"}).should be_a(Array(String))
  end
end
