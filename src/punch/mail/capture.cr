module Punch::Mailer
  # Keeps delivered mail in memory instead of sending it: for development,
  # where the ops console shows it (`/_punch/mail`), and for specs
  # (`Punch::Spec.mails`). Safe under parallel delivery; bounded to the
  # newest `MAX`.
  class Capture < Adapter
    MAX = 500

    # One captured mail.
    struct Captured
      getter id : Int64
      getter at : Time
      getter key : String
      getter type : String
      getter locale : String
      getter from : String
      getter to : Array(String)
      getter reply_to : String?
      getter subject : String
      getter text : String
      getter html : SafeHTML

      def initialize(@id, @at, @key, @type, @locale, @from, @to, @reply_to, @subject, @text, @html)
      end

      # Whether one recipient has address *address*.
      def to?(address : String) : Bool
        @to.any? { |recipient| recipient == address || recipient.ends_with?("<#{address}>") }
      end

      # The absolute URLs in the text part, in order.
      def links : Array(String)
        @text.scan(%r{https?://[^\s<>]+}).map(&.[0])
      end

      # The paths of the links to this app (below `Punch.public_url`), for
      # a spec client to follow.
      def paths : Array(String)
        links.compact_map(&.lchop?(Punch.public_url)).select(&.starts_with?('/'))
      end
    end

    @mutex = Mutex.new
    @mails = Deque(Captured).new
    @next_id = 0_i64

    def deliver_now(message : Message) : Nil
      @mutex.synchronize do
        @next_id += 1
        @mails.shift if @mails.size >= MAX
        @mails << Captured.new(@next_id, Time.utc, message.key, message.type, message.locale, message.from.to_s,
          message.to.map(&.to_s), message.reply_to.try(&.to_s), message.subject, message.text, message.html)
      end
    end

    # Every captured mail, newest first.
    def list : Array(Captured)
      @mutex.synchronize { @mails.to_a.reverse! }
    end

    def find(id : Int64) : Captured?
      @mutex.synchronize { @mails.find(&.id.==(id)) }
    end

    # The mails captured after the one with ID *id*, oldest first.
    def after(id : Int64) : Array(Captured)
      @mutex.synchronize { @mails.select(&.id.>(id)) }
    end

    # The ID of the newest mail; 0 before the first.
    def last_id : Int64
      @mutex.synchronize { @next_id }
    end

    def clear : Nil
      @mutex.synchronize { @mails.clear }
    end
  end
end
