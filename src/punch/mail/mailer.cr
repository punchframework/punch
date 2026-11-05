module Punch
  # The seam between an app and mail delivery. The app sends a `Punch::Mail`
  # from a job, normally a deferred subscriber, so mail goes out through the
  # outbox, after the Command committed:
  #
  # ```
  # def call(event : InvoiceSent, job : Punch::Job::Context) : Punch::Job::Result
  #   customer = job.read { |db| Customers::Table.find(db, event.customer_id) } || return discard("customer gone")
  #   Punch::Mailer.deliver(InvoiceMail.new(...), locale: Punch::I18n.locale(customer.locale.try(&.value)), job: job)
  # end
  # ```
  #
  # `deliver` renders the mail in the recipient's *locale* and hands it to
  # the adapter the credentials name (`Settings#delivery`): Punch's
  # capturing adapter, Punch's SMTP adapter, or an `Adapter` registered
  # with `Punch::Mailer.adapter`. It returns what the job
  # returns: `nil` when sent, `Punch::Job::Retry` when delivery failed and may
  # succeed later, `Punch::Job::Discard` when the server refused the recipient
  # for good.
  module Mailer
    # The parts of a rendered mail.
    record Rendered, subject : String, text : String, html : SafeHTML

    @@settings : Settings?
    @@adapter : Adapter?
    @@factory : Proc(Adapter)?
    @@forced : Capture?
    @@problems = [] of String

    # Registers the adapter for `delivery: adapter`, built at boot after
    # the credentials have loaded. Call it once, at the top level:
    #
    # ```
    # Punch::Mailer.adapter { Invoicing::Postmark.new(Invoicing::Credentials.current.postmark.token) }
    # ```
    def self.adapter(&block : -> Adapter) : Nil
      @@factory = block
    end

    # Sets up delivery from the app's settings; done at boot by the
    # credentials (*field* is where they are declared). Problems are kept
    # for the boot to report (`problems`).
    def self.configure(settings : Settings, field : String = "mail") : Nil
      @@settings = settings
      @@problems = [] of String
      @@adapter = case settings.delivery
                  in .capture? then Capture.new
                  in .smtp?
                    smtp = settings.smtp
                    if host = smtp.host.presence
                      SMTP.new(host, smtp.port, smtp.tls, smtp.username, smtp.password)
                    else
                      @@problems << "#{field}.smtp.host (#{Credentials.variable([field, "smtp", "host"])}) must be set when #{field}.delivery is smtp"
                      nil
                    end
                  in .adapter?
                    if factory = @@factory
                      factory.call
                    else
                      @@problems << "#{field}.delivery is adapter, but the app registers none with Punch::Mailer.adapter { ... }"
                      nil
                    end
                  end
    end

    # What is wrong with the settings for *environment*: outside
    # development and test, captured mail would never leave, and a password
    # over plain SMTP to another machine would cross the network readable.
    def self.environment_problems(environment : String, field : String = "mail") : Array(String)
      settings = @@settings || return [] of String
      return [] of String if environment.in?("development", "test")

      problems = [] of String
      problems << "#{field}.delivery is capture in #{environment}: no mail would leave; set smtp or adapter" if settings.delivery.capture?
      smtp = settings.smtp
      if settings.delivery.smtp? && smtp.tls.plain? && smtp.password && !smtp.host.in?("localhost", "127.0.0.1", "::1")
        problems << "#{field}.smtp.tls is plain with a password, to #{smtp.host}: use starttls or smtps"
      end
      problems
    end

    # What `configure` found wrong with the settings.
    # :nodoc:
    def self.problems : Array(String)
      @@problems
    end

    # The settings loaded at boot.
    def self.settings : Settings
      @@settings || raise Credentials::NotLoaded.new("No mail settings have been loaded. Declare `getter mail : Punch::Mailer::Settings` in the app's credentials (lib/punch/docs/mail.md); specs call Punch::Spec.credentials.")
    end

    # The adapter mail goes to.
    def self.current : Adapter
      @@forced || @@adapter || raise Credentials::NotLoaded.new("Mail has no adapter: the mail settings did not load (lib/punch/docs/mail.md).")
    end

    # The capturing adapter, when mail is captured in this process.
    def self.capture? : Capture?
      @@forced || @@adapter.as?(Capture)
    end

    # Captures every mail whatever the settings say: `punch/spec` does
    # this, so specs never send.
    # :nodoc:
    def self.force_capture(capture : Capture) : Nil
      @@forced = capture
    end

    # *mail* rendered in *locale*: the subject, the text part, and the HTML
    # part, with links absolute below `Punch.public_url`.
    def self.render(mail : Mail, locale : Locale) : Rendered
      subject = mail.subject(locale).gsub(/[[:cntrl:]]+/, " ").strip
      base = Punch.public_url
      text = View::TextBackend.new(base)
      View.new(text, View::State.new(locale: locale, mail: true)).render(mail)
      html = String.build do |io|
        io << "<!doctype html>\n<html lang=\""
        HTML.escape(locale.code, io)
        io << "\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>"
        HTML.escape(subject, io)
        io << "</title>\n</head>\n<body>\n"
        View.new(View::HTMLBackend.new(io, base), View::State.new(locale: locale, mail: true)).render(mail)
        io << "</body>\n</html>\n"
      end
      # Written by the views, which escape every value.
      # ameba:disable Punch/TrustedHTML
      Rendered.new(subject, text.to_s, SafeHTML.trusted(html))
    end

    # Renders *mail* in *locale*, the recipient's, and delivers it now, as
    # one span. Only from a job, which gives the delivery its key and
    # retries it: never inside a transaction, never from a request.
    def self.deliver(mail : Mail, *, locale : Locale, job : Job::Context) : Job::Result
      if Fiber.current.punch_writer?
        raise ArgumentError.new("#{mail.class} delivered inside a write transaction. Deliver mail from a job, after its writes (lib/punch/docs/mail.md).")
      end
      deliver_with(current, mail, locale, job.key)
    end

    # `deliver` through *adapter*, with *key* as the delivery's key.
    # :nodoc:
    def self.deliver_with(adapter : Adapter, mail : Mail, locale : Locale, key : String) : Job::Result
      settings = self.settings
      recipients = mail.to
      recipients = [recipients] unless recipients.is_a?(Array)
      raise ArgumentError.new("#{mail.class} has no recipient") if recipients.empty?
      type = mail.class.name
      Trace.event["punch.mail.type"] = type
      Trace.span("mail.deliver", :client) do |span|
        span.set("punch.mail.type", type)
        span.set("punch.mail.key", key)
        span.set("punch.mail.adapter", adapter.class.name)
        span.set("punch.mail.recipients", recipients.size)
        span.set("punch.locale", locale.code)
        rendered = render(mail, locale)
        message = Message.new(subject: rendered.subject, from: settings.sender, to: recipients, reply_to: mail.reply_to,
          text: rendered.text, html: rendered.html, key: key, type: type, locale: locale.code)
        begin
          adapter.deliver_now(message)
          nil
        rescue ex : DeliveryFailed
          span.error(ex.permanent? ? "rejected" : "failed")
          reason = ex.message || "delivery failed"
          ex.permanent? ? Job::Discard.new(reason) : Job::Retry.new(reason)
        rescue ex
          # A provider's adapter raises on an error answer: worth another
          # attempt, and seen in the console.
          span.error(ex)
          Job::Retry.new("mail delivery failed: #{ex.class}: #{ex.message}")
        end
      end
    end
  end
end
