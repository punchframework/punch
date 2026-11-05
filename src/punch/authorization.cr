module Punch
  # The policy that decides whether an actor may run an operation:
  # `@[Punch::Authorize(Invoices::Owner)]`. Every operation declares one, or
  # `@[Punch::Public]`; `punch check` fails otherwise.
  annotation Authorize
  end

  # Marks an operation that anyone may run, signed in or not: sign-in,
  # sign-up, a shared link. It needs no policy.
  annotation Public
  end

  # What a policy decides.
  enum Policy::Decision
    # The actor may run the operation.
    Allow
    # 403: the actor may see that the resource exists, but not do this.
    Forbid
    # 404: the actor must not learn that the resource exists.
    NotFound
    # 403 `reauthentication_required`: the actor may, after proving again
    # who they are (`Punch::Policy::RecentAuthentication`).
    Reauthenticate
  end

  # Included by a policy: a type with a class method `check` that decides
  # from the actor, a database handle, and the operation's path parameters
  # (docs/authorization.md):
  #
  # ```
  # struct Billing::Invoices::Owner
  #   include Punch::Policy
  #
  #   def self.check(actor : Invoicing::Actor, db : Punch::Reader | Punch::Writer, *, invoice_id : ID) : Punch::Policy::Decision
  #     owner = Queries.owner(db, invoice_id: invoice_id) || return allow # the operation answers its own 404
  #     owner == actor.user.id ? allow : not_found
  #   end
  # end
  # ```
  #
  # A policy never sees the body: forms and links ask it before they render
  # (`Punch::View`), when only the path is known. Rules about the body, such
  # as "the customer named must be one of yours", belong to the operation.
  #
  # A policy that asks roles names `operation` as its third parameter and
  # is told which operation asks:
  #
  # ```
  # def self.check(actor : Invoicing::Actor, db : Punch::Reader | Punch::Writer, operation : Punch::Operation.class, *, invoice_id : ID) : Punch::Policy::Decision
  #   organization = Queries.organization(db, invoice_id: invoice_id) || return allow
  #   Punch::Roles.check(db, actor.user.id, operation, on: organization)
  # end
  # ```
  module Policy
    macro included
      extend ::Punch::Policy::Decisions
    end

    # Shorthands for the three decisions inside `check`.
    module Decisions
      def allow : Policy::Decision
        Policy::Decision::Allow
      end

      def forbid : Policy::Decision
        Policy::Decision::Forbid
      end

      def not_found : Policy::Decision
        Policy::Decision::NotFound
      end
    end
  end

  # The policy of operations that any signed-in user may run. The
  # operation's `call` must take the actor, not nilable, so a request
  # without one is answered 401 before the policy runs.
  struct SignedIn
    include Policy

    def self.check(actor : Auth::Actor, db : Reader | Writer, **params) : Policy::Decision
      allow
    end
  end

  # An operation's policy said no: 403 `forbidden` for `Policy::Decision::Forbid`,
  # 404 `not_found` for `Policy::Decision::NotFound`, so existence does not leak.
  # 403 `reauthentication_required` for `Policy::Decision::Reauthenticate`. One
  # type for all keeps every operation's result union one member larger,
  # not three: unions are compiled per operation.
  struct Policy::Refused
    getter decision : Policy::Decision

    def initialize(@decision : Policy::Decision)
    end

    def status : ::HTTP::Status
      @decision.not_found? ? ::HTTP::Status::NOT_FOUND : ::HTTP::Status::FORBIDDEN
    end

    # The problem's code: `forbidden`, `not_found`, or
    # `reauthentication_required`.
    def code : String
      case @decision
      in .allow?, .forbid? then "forbidden"
      in .not_found?       then "not_found"
      in .reauthenticate?  then "reauthentication_required"
      end
    end
  end

  # Included by a policy that asks for a recent authentication before
  # sensitive changes: changing how someone signs in, deleting an account,
  # moving money. A browser left open must not let someone else make them.
  #
  # ```
  # struct Accounts::Recent
  #   include Punch::Policy
  #   include Punch::Policy::RecentAuthentication
  #
  #   def self.check(actor : Invoicing::Actor, db : Punch::Reader | Punch::Writer, **params) : Punch::Policy::Decision
  #     recently_authenticated(db, actor.principal)
  #   end
  # end
  # ```
  #
  # `openapi.json` lists 403 `reauthentication_required` on the operations
  # of such a policy. `Punch::RecentlyAuthenticated` is the policy that
  # asks only this.
  module Policy::RecentAuthentication
    macro included
      extend ::Punch::Policy::RecentAuthentication::Decisions
    end

    module Decisions
      # Allow when the session behind *principal* proved who the user is
      # within *within* (`Auth::Config#recent_authentication`, 15 minutes
      # by default), and if the user has a second factor, with it;
      # `reauthenticate` otherwise. An API token never qualifies: it
      # cannot prove anything again, so it is forbidden.
      def recently_authenticated(db : Reader | Writer, principal : Auth::Principal, within : Time::Span = Auth.config.recent_authentication,
                                 now : Time = Time.utc) : Policy::Decision
        Policy::RecentAuthentication.decide(db, principal, within, now)
      end

      def reauthenticate : Policy::Decision
        Policy::Decision::Reauthenticate
      end
    end

    # :nodoc:
    def self.decide(db : Reader | Writer, principal : Auth::Principal, within : Time::Span, now : Time) : Policy::Decision
      session = principal.session || return Policy::Decision::Forbid
      return Policy::Decision::Reauthenticate if session.authenticated_at < now - within
      return Policy::Decision::Allow if session.second_factor?

      Auth::SecondFactors.enabled?(db, principal.user_id) ? Policy::Decision::Reauthenticate : Policy::Decision::Allow
    end

    # Whether *principal* authenticated recently enough: for pages that
    # say why a form is missing.
    def self.recent?(db : Reader | Writer, principal : Auth::Principal, within : Time::Span = Auth.config.recent_authentication,
                     now : Time = Time.utc) : Bool
      decide(db, principal, within, now).allow?
    end
  end

  # The policy of operations that any signed-in user may run after a
  # recent authentication (`Punch::Policy::RecentAuthentication`). The app's actor
  # must have a `principal` getter.
  struct RecentlyAuthenticated
    include Policy
    include Policy::RecentAuthentication

    def self.check(actor : Auth::Actor, db : Reader | Writer, **params) : Policy::Decision
      recently_authenticated(db, actor.principal)
    end
  end

  # The proof that an operation's policy allowed it. A Command with a policy
  # takes `grant : Punch::Grant(Send)` in its `call`, so code that calls it
  # directly, a page or a job, must ask the policy first:
  #
  # ```
  # case grant = Punch::Grant(Send).check(actor, db, invoice_id: id)
  # in Punch::Grant(Send)     then Send.new.call(input, db, actor, grant)
  # in Punch::Policy::Refused then grant # grant.code: forbidden or not_found
  # end
  # ```
  #
  # `check` is the only way to make one: the constructor is private.
  struct Grant(O)
    private def initialize
    end

    # Runs *O*'s policy for *actor* with *params*, the operation's path
    # parameters, in *db*'s transaction.
    def self.check(actor, db : Reader | Writer, **params) : self | Policy::Refused
      {% O.raise "Punch::Grant(#{O}): #{O} has no policy. Declare one with @[Punch::Authorize(Policy)] (lib/punch/docs/authorization.md)." unless O.has_constant?("PunchPolicy") %}
      decision = Authorization.decided(O::PunchPolicy.name, decide(actor, db, **params))
      decision.allow? ? new : Policy::Refused.new(decision)
    end

    # *O*'s policy's decision. A policy whose `check` takes `operation`
    # after the handle is told which operation asks, as a role check needs
    # (`Punch::Roles.check`).
    # :nodoc:
    def self.decide(actor, db : Reader | Writer, **params) : Policy::Decision
      {% if parse_type("::#{O}::PunchPolicy").resolve.class.methods.any? { |method| method.name == "check" && method.args.size > 2 && method.args[2].name.stringify == "operation" } %}
        O::PunchPolicy.check(actor, db, O, **params)
      {% else %}
        O::PunchPolicy.check(actor, db, **params)
      {% end %}
    end

    # Whether *authorizer*'s actor may run *O* with *params*: what forms and
    # links ask before they render. An operation without a policy is
    # permitted; one that needs a signed-in user is not without one.
    # :nodoc:
    def self.permitted?(authorizer : Policy::Authorizer, **params) : Bool
      {% begin %}
        {% actor = nil %}
        {% for type in parse_type("::#{O}::PunchCallExtras").resolve.type_vars %}
          {% if type.union? %}
            {% members = type.union_types.reject(&.==(Nil)) %}
            {% actor = type if members.size == 1 && members[0] < Punch::Auth::Actor %}
          {% elsif type < Punch::Auth::Actor %}
            {% actor = type %}
          {% end %}
        {% end %}
        {% if O.has_constant?("PunchPolicy") %}
          {% if actor && actor.union? %}
            actor = authorizer.actor.as?({{ actor.union_types.reject(&.==(Nil)).first.stringify.gsub(::Punch::NAME_STARTS, "::").id }})
          {% elsif actor %}
            actor = authorizer.actor.as?({{ actor.stringify.gsub(::Punch::NAME_STARTS, "::").id }}) || return false
          {% end %}
          authorizer.permitted?(decide(actor, authorizer.db, **params))
        {% elsif actor && !actor.union? %}
          !authorizer.actor.nil?
        {% else %}
          true
        {% end %}
      {% end %}
    end
  end

  # Who is looking at a page, for the forms and links on it that ask their
  # operation's policy before they render. Pages are rendered inside their
  # read transaction, so a policy reads the same snapshot as the page.
  class Policy::Authorizer
    getter actor : Auth::Actor?
    getter db : Reader
    # Forms and links left out because their policy said no.
    getter hidden = 0

    def initialize(@actor : Auth::Actor?, @db : Reader)
    end

    # :nodoc:
    def permitted?(decision : Policy::Decision) : Bool
      return true if decision.allow?

      @hidden += 1
      false
    end
  end

  # :nodoc:
  module Authorization
    # Records a policy's decision on the wide event and returns it.
    def self.decided(policy : String, decision : Policy::Decision) : Policy::Decision
      event = Trace.event
      if event.recording?
        event.set("punch.policy", policy)
        event.set("punch.authz", decision.to_s.underscore)
      end
      decision
    end
  end
end
