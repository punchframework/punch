module Punch
  # A write refused by a unique constraint, as a value. `punch db:generate`
  # makes one struct per unique constraint of a mapped table, in the table's
  # module, named after its columns: `customers.email` becomes
  # `Billing::Customers::EmailTaken`. Every generated write that can hit the
  # constraint returns it as part of its result:
  #
  # ```
  # case created = Table.insert(db, name: input.name, email: input.email)
  # in Record     then Created.new(created)
  # in EmailTaken then created # 422 with `taken` at `email`
  # end
  # ```
  #
  # Returned from a Command, a violation answers like a rejected input: 422
  # with `taken` at its field, as Problem Details or as a field error on
  # the form. Its field is the constraint's one column that is not a
  # foreign key (`position` for `UNIQUE (invoice_id, position)`), or the
  # input as a whole when there is no such single column. When the input
  # names the field differently, return `violation.rejection(path...)`.
  module Database::Violation
    # The code every unique violation carries.
    CODE = "taken"

    # The generated struct defines `CONSTRAINT` and `FIELD`.
    macro included
      def initialize
      end

      def constraint : String
        CONSTRAINT
      end

      def field : String?
        FIELD
      end
    end

    # `table.column, …` of the constraint, or `table: index` for an index
    # on expressions; for the wide event and messages.
    abstract def constraint : String

    # The input field the violation belongs to by default, `nil` for the
    # input as a whole.
    abstract def field : String?

    # The error code: `taken`, or a trigger's rule's own
    # (`Punch.violation`).
    def code : String
      {% if @type.has_constant?("PROBLEM_CODE") %}
        {{ @type }}::PROBLEM_CODE
      {% else %}
        CODE
      {% end %}
    end

    # The violation as a rejection, at its own field.
    def rejection : Rejection
      if name = field
        Rejection.new(Rejection::Path{name}, Invalid.new(code))
      else
        Rejection.new(Rejection::Path.new, Invalid.new(code))
      end
    end

    # The violation as a rejection at *path*, for an input that names the
    # field differently or holds it in a row: `rejection("lines", 2, "position")`.
    def rejection(*path : String | Int32) : Rejection
      Rejection.new(Rejection::Path.new.concat(path), Invalid.new(code))
    end
  end

  # A write a trigger refused with a rule declared `status: 409`
  # (`Punch.violation`): answered as a problem with the rule's code, like
  # any result with `@[Punch::Status]` from 400 on, so a Command that
  # returns it rolls back.
  module Database::Refusal
    macro included
      def initialize
      end

      def constraint : String
        CONSTRAINT
      end

      def code : String
        PROBLEM_CODE
      end
    end
  end

  # Declares the rule a trigger enforces as a value of the writes that fire
  # it, in the `columns.cr` that maps the trigger's table:
  #
  # ```
  # # db/schema.sql
  # CREATE TRIGGER invoices_locked BEFORE UPDATE ON invoices
  # WHEN OLD.sent_at IS NOT NULL
  # BEGIN SELECT RAISE(ABORT, 'punch:invoice_locked'); END;
  #
  # # app/billing/invoices/columns.cr
  # Punch.violation "invoice_locked", Billing::Invoices::Locked, status: 409
  # ```
  #
  # `punch db:generate` checks that a trigger raises the code and writes
  # the type; with `status: 422` it answers like a rejected input, at
  # *field* when given.
  macro violation(code, type, *, status, field = nil)
    macro finished
      \{% found = parse_type({{ type.stringify }}).resolve? %}
      \{% unless found && found.has_constant?("PROBLEM_CODE") && found.constant("PROBLEM_CODE") == {{ code }} %}
        \{% raise "Punch.violation {{ code.id }}: {{ type.id }} is not generated for it; run punch db:generate (lib/punch/docs/queries.md)" %}
      \{% end %}
    end
  end

  # Returns the result of a generated write without its violations, for a
  # write that cannot violate by construction, such as positions numbered
  # by the code. A violation raises `Database::ConstraintError`: the
  # construction was wrong, which is a bug.
  #
  # ```
  # line = Punch.cannot_violate(Lines::Table.insert(db, invoice_id: id, position: 1_i64, ...))
  # ```
  def self.cannot_violate(result : T) forall T
    if result.is_a?(Database::Violation)
      raise Database::ConstraintError.new("#{result.constraint} was violated by a write that cannot violate it", 2067)
    end
    if result.is_a?(Database::Refusal)
      raise Database::ConstraintError.new("#{result.constraint} was violated by a write that cannot violate it", 2067)
    end
    result
  end
end
