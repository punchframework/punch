# Calls the generator finds; `inbox.title` is never called, so it is
# reported as unused.
module Fixture::Greeter
  def self.greet(locale : Punch::Locale, name : String, unread : Int32) : String
    t = locale.t
    "#{t.greeting(name: name)} #{t.inbox.messages(count: unread, folder: "INBOX")}"
  end

  struct WrongAmount
    def self.check(total : Int64) : Punch::Invalid?
      Punch::Invalid.new("wrong_amount", total: total) if total < 0
    end
  end

  @[Punch::Status(409)]
  struct AlreadySent
  end
end
