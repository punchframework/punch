module Punch::Spec
  # Every mail delivered in a spec binary: `punch/spec` makes it the
  # adapter, whatever the credentials say, so specs never send.
  MAILS = Mailer::Capture.new

  @@mail_mark = 0_i64

  # The mails delivered in this example, oldest first: what
  # `perform_jobs` delivered.
  #
  # ```
  # Punch::Spec.perform_jobs
  # mail = Punch::Spec.mails(to: "ada@example.org").first
  # mail.subject.should eq("Invoice A-1")
  # client.visit(mail.paths.first)
  # ```
  def self.mails : Array(Mailer::Capture::Captured)
    MAILS.after(@@mail_mark)
  end

  # The mails of this example with *address* among the recipients.
  def self.mails(*, to address : String) : Array(Mailer::Capture::Captured)
    mails.select(&.to?(address))
  end

  # *mail* rendered in *locale* (the default one unless given), as
  # `Punch::Mailer.deliver` renders it, for specs of a mail's content.
  def self.render_mail(mail : Mail, locale : Locale = I18n.default) : Mailer::Rendered
    Mailer.render(mail, locale)
  end

  # :nodoc:
  def self.mark_mails : Nil
    @@mail_mark = MAILS.last_id
  end

  # What `deliver_mail` matches: a block during which mails of type *T*
  # were delivered, to *to* when given, *times* times when given.
  class DeliverMailExpectation(T)
    @new = [] of Mailer::Capture::Captured
    @matching = [] of Mailer::Capture::Captured

    def initialize(@to : String?, @times : Int32?)
    end

    def match(actual : Proc) : Bool
      before = MAILS.last_id
      actual.call
      @new = MAILS.after(before)
      to = @to
      @matching = @new.select { |mail| mail.type == {{ T.name.stringify }} && (to.nil? || mail.to?(to)) }
      (times = @times) ? @matching.size == times : !@matching.empty?
    end

    def failure_message(actual : Proc) : String
      got = @new.map { |mail| "#{mail.type} to #{mail.to.join(", ")}" }
      "Expected the block to deliver #{describe}\n     got: #{got.empty? ? "no mail" : got.join("; ")}"
    end

    def negative_failure_message(actual : Proc) : String
      "Expected the block not to deliver #{describe}\n     got: #{@matching.size}"
    end

    private def describe : String
      String.build do |io|
        io << (@times.try { |times| "#{times} × " } || "") << T
        @to.try { |address| io << " to " << address }
      end
    end
  end
end

Punch::Mailer.force_capture(Punch::Spec::MAILS)
Spec.before_each { Punch::Spec.mark_mails }

# `->{ Punch::Spec.perform_jobs }.should deliver_mail(InvoiceMail, to: "ada@example.org")`:
# the block delivered at least one mail of this type, to this address
# when given; `times: n` for exactly *n*.
def deliver_mail(type : T.class, *, to : String? = nil, times : Int32? = nil) forall T
  {% raise "deliver_mail(#{T}): #{T} is not a mail (include Punch::Mail)" unless T < ::Punch::Mail %}
  Punch::Spec::DeliverMailExpectation(T).new(to, times)
end
