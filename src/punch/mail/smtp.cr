module Punch::Mailer
  # Sends by SMTP over crystal-email, and raises when the server refuses.
  #
  # With `TLS::Starttls` (the default) the upgrade must succeed; the
  # server's certificate and host name are verified, and credentials are
  # sent only after TLS. One SMTP session per mail.
  class SMTP < Adapter
    # Seconds, as crystal-email takes them.
    CONNECT_TIMEOUT = 10
    IO_TIMEOUT      = 30

    # crystal-email logs every session to stdout, where the wide events go;
    # failures reach the job as `DeliveryFailed` instead.
    QUIET = ::Log.new("punch.mail.smtp", nil, :none)

    def initialize(@host : String, @port : Int32, @tls : TLS, @username : String?, @password : Secret(String)?)
    end

    def deliver_now(message : Message) : Nil
      mail = EMail::Message.new
      mail.from(message.from.email.value, message.from.header_name)
      message.to.each { |address| mail.to(address.email.value, address.header_name) }
      unsendable = ([message.from] + message.to).find { |address| !address.email.value.ascii_only? }
      # crystal-email speaks no SMTPUTF8: such a mail can never go.
      raise DeliveryFailed.new("SMTP cannot send to or from #{unsendable.email.value}: international addresses need SMTPUTF8", permanent: true) if unsendable
      message.reply_to.try { |address| mail.reply_to(address.email.value, address.header_name) }
      mail.subject(message.subject)
      message.text.presence.try { |text| mail.message(text) }
      message.html.value.presence.try { |html| mail.message_html(html) }
      history = nil
      config = EMail::Client::Config.new(@host, @port, helo_domain: message.from.email.value.rpartition('@').last.presence || "localhost")
      config.use_tls(case @tls
      in .starttls? then EMail::Client::TLSMode::STARTTLS
      in .smtps?    then EMail::Client::TLSMode::SMTPS
      in .plain?    then EMail::Client::TLSMode::NONE
      end)
      if (username = @username) && (password = @password)
        config.use_auth(username, password.unwrap)
      end
      config.connect_timeout = CONNECT_TIMEOUT
      config.read_timeout = IO_TIMEOUT
      config.write_timeout = IO_TIMEOUT
      config.log = QUIET
      config.on_failed = EMail::Client::OnFailedProc.new { |_mail, commands| history = commands.dup; nil }
      sent = false
      begin
        EMail::Client.new(config).start { sent = send(mail) }
      rescue ex : EMail::Error | IO::Error | Socket::Error | OpenSSL::Error
        raise DeliveryFailed.new("SMTP #{@host}:#{@port}: #{ex.message}")
      end
      return if sent

      raise SMTP.failure(history)
    end

    # What a failed session says: the server's last refusal, permanent
    # when it answered `RCPT` with 5xx. Without a history the session
    # never got that far (connection, STARTTLS, or authentication).
    def self.failure(history : Array(String)?) : DeliveryFailed
      lines = history || return DeliveryFailed.new("SMTP session could not be set up (connection, STARTTLS, or authentication refused)")
      index = lines.rindex(&.matches?(/\A[45]\d\d[ -]/)) || return DeliveryFailed.new("SMTP delivery failed")
      reply = lines[index]
      command = lines[0...index].reverse_each.find { |line| !line.matches?(/\A\d\d\d[ -]/) } || ""
      permanent = reply.starts_with?('5') && command.starts_with?("RCPT")
      DeliveryFailed.new("SMTP #{command.split(' ', 2).first? || "session"} refused: #{reply}", permanent: permanent)
    end
  end
end
