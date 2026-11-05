module Punch::Mailer
  # How mail leaves this process.
  enum Delivery
    # Kept in memory and shown in the ops console (`/_punch/mail`); for
    # development. Nothing is sent.
    Capture
    # Sent by SMTP (`Settings#smtp`).
    Smtp
    # Sent by the adapter the app registers with
    # `Punch::Mailer.adapter { ... }`, such as a provider's HTTP API.
    Adapter
  end

  # How the SMTP connection is secured.
  enum TLS
    # Plain connection upgraded with STARTTLS, which must succeed (port 587).
    Starttls
    # TLS from the start (port 465).
    Smtps
    # No TLS: only for a relay on the same host or network.
    Plain
  end

  # The app's mail settings, as a group in its credentials:
  #
  # ```
  # struct Invoicing::Credentials
  #   include Punch::Credentials
  #   getter mail : Punch::Mailer::Settings
  # end
  # ```
  #
  # ```yaml
  # mail:
  #   delivery: smtp          # capture, smtp, or adapter
  #   from: invoices@example.org
  #   from_name: Example Invoicing
  #   smtp:
  #     host: smtp.example.org
  #     username: invoices
  #     password: …
  # ```
  #
  # As every credential, each value can come from the environment:
  # `MAIL__DELIVERY=capture`, `MAIL__SMTP__PASSWORD=…`.
  struct Settings
    include Credentials

    getter delivery : Delivery
    # The sender of every mail.
    getter from : Email
    getter from_name : String?
    getter smtp : SMTPSettings

    # The sender as an address.
    def sender : Mail::Address
      Mail::Address.new(from, from_name)
    end
  end

  # The SMTP server, for `delivery: smtp`.
  struct SMTPSettings
    include Credentials

    getter host : String?
    getter port : Int32 = 587
    getter username : String?
    getter password : Secret(String)?
    getter tls : TLS = TLS::Starttls
  end
end
