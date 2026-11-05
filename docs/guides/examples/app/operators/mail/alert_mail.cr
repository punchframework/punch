module Operators
  # Tells the operators what went wrong, in one line, and where to look.
  struct AlertMail
    include Punch::Mail

    def initialize(@to : Punch::Email, @summary : String)
    end

    def to : Punch::Mail::Address
      Punch::Mail::Address.new(@to)
    end

    def subject(locale : Punch::Locale) : String
      locale.t.operators.alert.subject(summary: @summary)
    end

    def view(v : Punch::View) : Nil
      v.p @summary
      v.p v.t.operators.alert.body
    end
  end
end
