module Punch::Ops::Console
  # ---- Inbound webhooks ---------------------------------------------------

  # A webhook provider's name in a query.
  struct ProviderName
    include Punch::Primitive(String)

    def self.parse(raw : String) : self | Punch::Invalid
      raw.matches?(/\A[a-z][a-z0-9_-]{0,62}\z/) ? new(raw) : Punch::Invalid.new("invalid_provider")
    end
  end

  # An invocation's state in a query.
  enum InvocationState
    Received
    Verified
    Processed
    Ignored
    Failed
    Unprocessable
    Rejected
  end

  # Stored bodies are shown up to this many bytes.
  MAX_BODY = 65_536

  struct WebhooksOverview
    include Punch::Component

    def initialize(@providers : Array({String, String, String}), @counts : Array({String, String, Int64}),
                   @invocations : Array(Webhook::Invocations::Listed), @provider : ProviderName?, @state : InvocationState?)
    end

    def view(v : Punch::View) : Nil
      v.render Layout.new("Webhooks") do
        v.h1 "Inbound webhooks"
        if @providers.empty?
          v.p "This app has no webhook provider."
          next
        end
        providers(v)
        invocations(v)
      end
    end

    private def providers(v : Punch::View) : Nil
      v.section do
        v.h2 "Providers"
        states = Webhook::Invocations::STATES
        v.table(class: "providers") do
          v.thead { v.tr { (["Provider", "Verification"] + states).each { |label| v.th label, scope: "col" } } }
          v.tbody do
            @providers.each do |name, type, verification|
              v.tr do
                v.th(scope: "row") do
                  provider = ProviderName.parse(name).as?(ProviderName)
                  provider ? v.a(name, href: WebhooksPage.href(provider: provider)) : v.text(name)
                  v.br
                  v.small type
                end
                v.td verification
                states.each do |state|
                  count = @counts.find { |provider, stored, _| provider == name && stored == state }.try(&.[2]) || 0_i64
                  v.td count.to_s
                end
              end
            end
          end
        end
      end
    end

    private def invocations(v : Punch::View) : Nil
      v.section do
        title = "Latest invocations"
        title += " of #{@provider}" if @provider
        title += ", #{@state.to_s.downcase}" if @state
        v.h2 title
        v.p do
          v.text "State: "
          v.a "all", href: WebhooksPage.href(provider: @provider)
          InvocationState.each do |state|
            v.text " "
            v.a state.to_s.downcase, href: WebhooksPage.href(provider: @provider, state: state)
          end
        end
        if @invocations.empty?
          v.p "None."
          return
        end
        v.table(class: "invocations") do
          v.thead { v.tr { ["Invocation", "Provider", "State", "Attempts", "Received", "Finished", "Error"].each { |label| v.th label, scope: "col" } } }
          v.tbody do
            @invocations.each do |invocation|
              v.tr do
                v.td { v.a invocation.id.to_s, href: WebhookPage.href(invocation_id: invocation.id) }
                v.td invocation.provider
                v.td invocation.state
                v.td invocation.attempts.to_s
                v.td Console.time(invocation.received_at)
                v.td Console.time(invocation.finished_at)
                v.td Console.first_line(invocation.error)
              end
            end
          end
        end
      end
    end
  end

  # `GET /_punch/webhooks`: the providers with their invocations per
  # state, and the latest invocations of one provider (`?provider=`) or
  # in one state (`?state=failed`).
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::AgentReadable]
  @[Punch::Route("GET", "/_punch/webhooks")]
  struct WebhooksPage < Punch::Page
    struct Input
      include Punch::Input

      getter provider : ProviderName?
      getter state : InvocationState?
    end

    alias Output = WebhooksOverview

    def call(input : Input, db : Punch::Reader, actor : Viewer) : Output
      providers = Webhook.providers
      if providers.empty?
        return WebhooksOverview.new(providers, [] of {String, String, Int64}, [] of Webhook::Invocations::Listed, nil, nil)
      end

      invocations = Webhook::Invocations.list(db, provider: input.provider.try(&.to_s), state: input.state.try(&.to_s.downcase), limit: 100)
      WebhooksOverview.new(providers, Webhook::Invocations.counts(db), invocations, input.provider, input.state)
    end
  end

  struct WebhookDetail
    include Punch::Component

    def initialize(@stored : Webhook::Invocations::Stored)
    end

    def view(v : Punch::View) : Nil
      stored = @stored
      invocation = stored.listed
      v.render Layout.new("Invocation #{invocation.id}") do
        v.h1 "Invocation #{invocation.id} of #{invocation.provider}"
        v.dl(class: "facts") do
          v.dt "State"
          v.dd invocation.state
          v.dt "Key"
          v.dd { v.code invocation.key }
          v.dt "Attempts"
          v.dd invocation.attempts.to_s
          v.dt "Received"
          v.dd Console.time(invocation.received_at)
          v.dt "Verified"
          v.dd Console.time(stored.verified_at)
          v.dt "Finished"
          v.dd Console.time(invocation.finished_at)
          invocation.error.try { |error| v.dt "Error"; v.dd error }
        end
        if invocation.state.in?(Webhook::Invocations::RETRY)
          v.p invocation.state == "rejected" ? "Retrying checks the signature again, as of when it was received, then processes it." : "Retrying processes it again from the stored request."
          v.form(RetryWebhook.action(invocation_id: invocation.id)) { |form| form.submit "Retry" }
        elsif invocation.state.in?(Webhook::Invocations::REPLAY)
          v.p "Replaying runs the provider's process for this delivery a second time: only for a handler that is safe to repeat, or after a fix."
          v.form(ReplayWebhook.action(invocation_id: invocation.id)) { |form| form.submit "Replay" }
        end
        v.h2 "Headers"
        if stored.headers.empty?
          v.p "None kept."
        else
          v.dl(class: "headers") do
            stored.headers.each do |name, value|
              v.dt name
              v.dd { v.code value }
            end
          end
        end
        v.h2 "Body (#{Console.bytes(stored.body.size.to_i64)})"
        body = stored.body.size > MAX_BODY ? stored.body[0, MAX_BODY] : stored.body
        v.pre String.new(body).scrub
        v.p "Shown up to #{Console.bytes(MAX_BODY.to_i64)}." if stored.body.size > MAX_BODY
      end
    end
  end

  # `GET /_punch/webhooks/:invocation_id`: one invocation with the request
  # as stored, and retry or replay.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::AgentReadable]
  @[Punch::Route("GET", "/_punch/webhooks/:invocation_id")]
  @[Punch::Forms(RetryWebhook, ReplayWebhook)]
  struct WebhookPage < Punch::Page
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter invocation_id : Int64
    end

    alias Output = WebhookDetail | NotFound

    def call(input : Input, db : Punch::Reader, actor : Viewer) : Output
      return NotFound.new unless Webhook.used?

      stored = Webhook::Invocations.stored(db, input.invocation_id) || return NotFound.new
      WebhookDetail.new(stored)
    end
  end

  # What retrying or replaying an invocation answers: its state now.
  struct InvocationMoved
    include JSON::Serializable

    getter id : Int64
    getter state : String

    def initialize(@id, @state)
    end
  end

  # Moves *id* back to be processed, or says why not.
  protected def self.again(db : Punch::Writer, id : Int64, replay : Bool) : InvocationMoved | NotFound | WrongState
    return NotFound.new unless Webhook.used?

    found = Webhook.again(db, id, replay: replay)
    stored = Webhook::Invocations.stored(db, id) || return NotFound.new
    found ? InvocationMoved.new(id, stored.listed.state) : WrongState.new(stored.listed.state)
  end

  # `POST /_punch/webhooks/:invocation_id/retry`: processes a failed or
  # unprocessable invocation again from its stored request; a rejected
  # one has its signature checked again first. 409 `wrong_state` for any
  # other.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::Route("POST", "/_punch/webhooks/:invocation_id/retry")]
  struct RetryWebhook < Punch::Command
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter invocation_id : Int64
    end

    alias Output = InvocationMoved | NotFound | WrongState

    def call(input : Input, db : Punch::Writer, actor : Viewer, grant : Punch::Grant(RetryWebhook)) : Output
      Console.again(db, input.invocation_id, replay: false)
    end
  end

  # `POST /_punch/webhooks/:invocation_id/replay`: processes a processed,
  # ignored, or discarded invocation once more from its stored request. 409
  # `wrong_state` for any other.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::Route("POST", "/_punch/webhooks/:invocation_id/replay")]
  struct ReplayWebhook < Punch::Command
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter invocation_id : Int64
    end

    alias Output = InvocationMoved | NotFound | WrongState

    def call(input : Input, db : Punch::Writer, actor : Viewer, grant : Punch::Grant(ReplayWebhook)) : Output
      Console.again(db, input.invocation_id, replay: true)
    end
  end
end
