module Punch
  # Included by a role: a set of operations, defined in code and reviewed
  # in a pull request. Who holds it, and on which resource, is data: rows in
  # `punch_role_assignments` (docs/authorization.md).
  #
  # ```
  # module Accounts::Roles
  #   # Reads everything in an organization.
  #   struct Member
  #     include Punch::Role
  #     scope Accounts::Organizations::ID
  #     permits Billing::Invoices::Index, Billing::Invoices::Show
  #   end
  #
  #   # A member who also writes and sends invoices.
  #   struct Accountant
  #     include Punch::Role
  #     scope Accounts::Organizations::ID
  #     permits Member, Billing::Invoices::Create, Billing::Invoices::Send
  #   end
  # end
  # ```
  #
  # `scope` names the typed ID of the resource the role is held on; a role
  # without one is held everywhere (a global role). `permits` lists
  # operations, and roles of the same scope whose operations it includes.
  # A role's name in the data is its type's name, dotted like an
  # operation's ID (`accounts.roles.accountant`): renaming the type needs
  # a migration that renames the rows.
  module Role
    macro included
      {% unless @type.struct? %}
        {% @type.raise "#{@type} includes Punch::Role, so it must be a struct: a role is a name and a set of operations, never instantiated (lib/punch/docs/authorization.md)." %}
      {% end %}

      # The resource this role is held on: the typed ID of an organization,
      # a project, ...
      macro scope(type)
        \{% if @type.has_constant?("PUNCH_ROLE_SCOPE") %}
          \{% type.raise "#{@type}: `scope` is given once." %}
        \{% end %}
        # :nodoc:
        alias PUNCH_ROLE_SCOPE = \{{ type }}
      end

      # The operations this role may run: operations, and roles of the
      # same scope whose operations it includes.
      macro permits(*types)
        \{% if @type.has_constant?("PUNCH_ROLE_PERMITS") %}
          \{% types[0].raise "#{@type}: list every operation in one `permits`." %}
        \{% end %}
        # :nodoc:
        alias PUNCH_ROLE_PERMITS = Tuple(\{{ types.splat }})
      end

      macro finished
        \{% @type.raise "#{@type} includes Punch::Role but permits nothing. List its operations: `permits Invoices::Index, Invoices::Show` (lib/punch/docs/authorization.md)." unless @type.has_constant?("PUNCH_ROLE_PERMITS") %}
        \{% if @type.has_constant?("PUNCH_ROLE_SCOPE") %}
          \{% scope = parse_type("::#{@type}::PUNCH_ROLE_SCOPE").resolve %}
          \{% @type.raise "#{@type}: `scope #{scope}` names a resource by its typed ID, a type that inherits from Punch::TypedID." unless scope < ::Punch::TypedID %}
        \{% end %}
      end
    end
  end

  # Roles: their definitions from code, assignments to users, and the
  # decision a policy asks for (docs/authorization.md).
  #
  # Assignments are rows in `punch_role_assignments`, scoped to a resource
  # (`resource_type`, `resource_id`) or global (both `NULL`), and may
  # expire. `punch_role_operations` holds every role's operations as the
  # code defines them; Punch writes it when the server starts (`sync`). The
  # view `punch_permissions` joins the two over live assignments: one row
  # per user, operation, and resource. Named queries join against it, so a
  # list shows only what the actor may see, with right page sizes.
  module Roles
    # One role as the code defines it.
    record Definition, name : String, scope : String?, operations : Array(String) do
      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "name", name
          json.field "scope", scope
          json.field "operations", operations
        end
      end
    end

    # One row of `punch_role_assignments`: *user_id* holds *role* on a
    # resource, or everywhere when *resource_type* is `nil`.
    struct Assignment
      getter id : Int64
      getter user_id : Int64
      getter role : String
      getter resource_type : String?
      getter resource_id : Int64?
      getter expires_at : Time?
      getter assigned_by : Int64?
      getter created_at : Time

      def initialize(@id, @user_id, @role, @resource_type, @resource_id, @expires_at, @assigned_by, @created_at)
      end

      def expired?(now : Time = Time.utc) : Bool
        expires_at.try { |time| time <= now } || false
      end

      # `accounts.roles.member on accounts.organizations 5`, or the role
      # alone for a global one.
      def to_s(io : IO) : Nil
        io << role
        if type = resource_type
          io << " on " << type << ' ' << resource_id
        end
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "id", id
          json.field "user_id", user_id
          json.field "role", role
          json.field "resource_type", resource_type
          json.field "resource_id", resource_id
          json.field "expires_at", expires_at
          json.field "assigned_by", assigned_by
          json.field "created_at", created_at
        end
      end
    end

    TABLE   = "punch_role_assignments"
    COLUMNS = "id, user_id, role, resource_type, resource_id, expires_at, assigned_by, created_at"

    # Whether an assignment `a` is live. Expiry is to the second: stored
    # times are longer than this form, so an assignment that expires
    # within the current second still counts until the next one.
    LIVE = "(a.expires_at IS NULL OR a.expires_at > strftime('%Y-%m-%dT%H:%M:%S', 'now'))"

    # The roles of this binary, from every type that includes `Punch::Role`.
    def self.definitions : Array(Definition)
      {% begin %}
        [
          {% for role in Punch::Role.includers.reject(&.abstract?) %}
            {% scope = role.has_constant?("PUNCH_ROLE_SCOPE") ? parse_type("::#{role}::PUNCH_ROLE_SCOPE").resolve : nil %}
            {% operations = [] of StringLiteral %}
            {% pending = role.has_constant?("PUNCH_ROLE_PERMITS") ? parse_type("::#{role}::PUNCH_ROLE_PERMITS").resolve.type_vars : [] of TypeNode %}
            {% seen = [role] %}
            {% for _ in 0..20 %}
              {% unless pending.empty? %}
                {% next_pending = [] of TypeNode %}
                {% for type in pending %}
                  {% if type < Punch::Role %}
                    {% included = type.has_constant?("PUNCH_ROLE_SCOPE") ? parse_type("::#{type}::PUNCH_ROLE_SCOPE").resolve : nil %}
                    {% unless included == scope %}
                      {% raise "#{role} permits #{type}, a role on #{included || "everything (global)".id}, but #{role} is held on #{scope || "everything (global)".id}. A role includes only roles of its own scope." %}
                    {% end %}
                    {% unless seen.includes?(type) %}
                      {% seen << type %}
                      {% next_pending = next_pending + parse_type("::#{type}::PUNCH_ROLE_PERMITS").resolve.type_vars %}
                    {% end %}
                  {% elsif type < Punch::Operation %}
                    {% id = type.name.split("::").map(&.underscore).join(".") %}
                    {% operations << id unless operations.includes?(id) %}
                  {% else %}
                    {% raise "#{role} permits #{type}, which is neither an operation nor a role." %}
                  {% end %}
                {% end %}
                {% pending = next_pending %}
              {% end %}
            {% end %}
            {% raise "#{role} includes roles more than 20 deep; flatten the chain." unless pending.empty? %}
            Definition.new({{ role.name.split("::").map(&.underscore).join(".") }},
              {{ scope ? scope.name.split("::").map(&.underscore).reject(&.==("id")).join(".") : nil }},
              {{ operations.sort }} of String),
          {% end %}
        ] of Definition
      {% end %}
    end

    # Whether this binary defines roles, so serving it needs the tables.
    # Punch's own roles (`Ops::Console::Operations`) do not count: they
    # are there to be included by the app's.
    def self.used? : Bool
      {{ Punch::Role.includers.reject(&.name.starts_with?("Punch::")).size > 0 }}
    end

    # The name of a resource type in the data: its typed ID's name, dotted
    # and without a final `ID` (`accounts.organizations`).
    def self.resource_type(type : T.class) : String forall T
      {{ T.name.split("::").map(&.underscore).reject(&.==("id")).join(".") }}
    end

    # Writes the operations of every role into `punch_role_operations`, so
    # `punch_permissions` matches this binary's code; a no-op when they
    # already do. The server calls it when it starts, and `Punch::Spec`
    # when it loads a schema.
    def self.sync(database : Database) : Nil
      wanted = definitions.flat_map { |role| role.operations.map { |operation| {role.name, operation} } }.to_set
      database.write do |db|
        stored = db.query_all("SELECT role, operation FROM punch_role_operations", name: "Punch::Roles.sync") do |row|
          {row.read(String), row.read(String)}
        end.to_set
        next if stored == wanted
        db.exec("DELETE FROM punch_role_operations", name: "Punch::Roles.sync")
        wanted.each do |(role, operation)|
          db.exec("INSERT INTO punch_role_operations (role, operation) VALUES (?, ?)", role, operation, name: "Punch::Roles.sync")
        end
      end
    end

    # Gives *user_id* the role *role* on *resource*, until *expires_at*
    # if given; assigning a role the user holds already changes only its
    # expiry. *assigned_by* is the user who decided it. Publish
    # `Roles::Assigned` with the result from the Command that calls it.
    def self.assign(db : Writer, user_id : TypedID | Int64, role : R.class, *, on resource : TypedID,
                    expires_at : Time? = nil, assigned_by : TypedID | Int64? = nil, now : Time = Time.utc) : Assignment forall R
      check_scope(R, resource)
      write(db, raw(user_id), role_name(R), resource_type(typeof(resource)), resource.value, expires_at, raw(assigned_by), now)
    end

    # Gives *user_id* the global role *role*.
    def self.assign(db : Writer, user_id : TypedID | Int64, role : R.class, *,
                    expires_at : Time? = nil, assigned_by : TypedID | Int64? = nil, now : Time = Time.utc) : Assignment forall R
      check_scope(R, nil)
      write(db, raw(user_id), role_name(R), nil, nil, expires_at, raw(assigned_by), now)
    end

    # Takes the role *role* on *resource* from *user_id*. Returns the
    # assignment that ended, or `nil` when there was none.
    def self.revoke(db : Writer, user_id : TypedID | Int64, role : R.class, *, on resource : TypedID) : Assignment? forall R
      check_scope(R, resource)
      delete(db, raw(user_id), role_name(R), resource_type(typeof(resource)), resource.value)
    end

    # Takes the global role *role* from *user_id*.
    def self.revoke(db : Writer, user_id : TypedID | Int64, role : R.class) : Assignment? forall R
      check_scope(R, nil)
      delete(db, raw(user_id), role_name(R), nil, nil)
    end

    # Ends every assignment on *resource*, for the Command that deletes it:
    # a resource ID has no foreign key that could do it.
    def self.revoke_all(db : Writer, *, on resource : TypedID) : Array(Assignment)
      db.lease.roles_held = nil
      db.query_all(<<-SQL, resource_type(typeof(resource)), resource.value, name: "Punch::Roles.revoke_all") { |row| read(row) }
        DELETE FROM punch_role_assignments WHERE resource_type = ? AND resource_id = ?
        RETURNING #{COLUMNS}
        SQL
    end

    # Gives *user_id* the global role named *role* (`accounts.roles.operator`),
    # for `roles:assign` on the box, where no type is at hand. Returns
    # `nil` when this binary defines no global role by that name.
    def self.assign_global(db : Writer, user_id : Int64, role : String, *, now : Time = Time.utc) : Assignment?
      return unless global?(role)

      write(db, user_id, role, nil, nil, nil, nil, now)
    end

    # Takes the global role named *role* from *user_id*: the assignment
    # that ended, or `nil` when there was none.
    def self.revoke_global(db : Writer, user_id : Int64, role : String) : Assignment?
      delete(db, user_id, role, nil, nil)
    end

    # Whether this binary defines a global role named *role*.
    def self.global?(role : String) : Bool
      definitions.any? { |definition| definition.name == role && definition.scope.nil? }
    end

    # The assignments of *user_id*, expired ones included, oldest first.
    def self.assignments(db : Reader | Writer, *, user_id : TypedID | Int64) : Array(Assignment)
      db.query_all(<<-SQL, raw(user_id), name: "Punch::Roles.assignments") { |row| read(row) }
        SELECT #{COLUMNS} FROM punch_role_assignments WHERE user_id = ? ORDER BY id
        SQL
    end

    # The assignments on *resource*, expired ones included, oldest first.
    def self.assignments(db : Reader | Writer, *, on resource : TypedID) : Array(Assignment)
      db.query_all(<<-SQL, resource_type(typeof(resource)), resource.value, name: "Punch::Roles.assignments") { |row| read(row) }
        SELECT #{COLUMNS} FROM punch_role_assignments WHERE resource_type = ? AND resource_id = ? ORDER BY id
        SQL
    end

    # How many users hold *role* on *resource*, live assignments only: for
    # a Command that keeps at least one administrator.
    def self.holders(db : Reader | Writer, role : R.class, *, on resource : TypedID) : Int64 forall R
      check_scope(R, resource)
      db.query_one?(<<-SQL, role_name(R), resource_type(typeof(resource)), resource.value, name: "Punch::Roles.holders", &.read(Int64)) || 0_i64
        SELECT count(*) FROM punch_role_assignments a
        WHERE a.role = ? AND a.resource_type = ? AND a.resource_id = ? AND #{LIVE}
        SQL
    end

    # The decision for a policy: whether *user_id* holds a live role that
    # permits *operation*, on *resource* or globally.
    #
    # - `allow`: a role permits it.
    # - `forbid` (403): the user holds a role on the resource, or a global
    #   one, but none permits this operation. They may know it exists.
    # - `not_found` (404): the user holds nothing there, so learns nothing.
    #
    # The wide event records the roles that decided (`punch.roles`).
    def self.check(db : Reader | Writer, user_id : TypedID | Int64, operation : O.class, *, on resource : TypedID) : Policy::Decision forall O
      decide(db, raw(user_id), operation_id(O), resource_type(typeof(resource)), resource.value)
    end

    # The decision for an operation with no resource: global roles only.
    def self.check(db : Reader | Writer, user_id : TypedID | Int64, operation : O.class) : Policy::Decision forall O
      decide(db, raw(user_id), operation_id(O), nil, nil)
    end

    # The name of *role* in `punch_role_assignments`.
    def self.role_name(role : R.class) : String forall R
      {% raise "#{R} is not a role: a role includes Punch::Role" unless R < Punch::Role %}
      {{ R.name.split("::").map(&.underscore).join(".") }}
    end

    # :nodoc:
    def self.operation_id(operation : O.class) : String forall O
      {% raise "Punch::Roles.check: #{O} is not an operation" unless O < Punch::Operation %}
      {{ O.name.split("::").map(&.underscore).join(".") }}
    end

    # The live assignments of *user_id*, oldest first: what `check` decides
    # from, read once per transaction and shared with it. For app code that
    # needs the user's resources on every request, such as the
    # organization they work in.
    def self.held(db : Reader | Writer, user_id : TypedID | Int64) : Array(Held)
      raw = raw(user_id)
      memo = (db.lease.roles_held ||= {} of Int64 => Array(Held))
      memo[raw] ||= db.query_all(<<-SQL, raw, name: "Punch::Roles.held") do |row|
        SELECT a.role, a.resource_type, a.resource_id
        FROM punch_role_assignments a
        WHERE a.user_id = ? AND #{LIVE}
        ORDER BY a.id
        SQL
        Held.new(row.read(String), row.read(String?), row.read(Int64?))
      end
    end

    # One live assignment of a user: the role, and the resource it is held
    # on (both `nil` for a global role).
    record Held, role : String, resource_type : String?, resource_id : Int64?

    # Each role's operations as this binary's code defines them: what
    # `punch_role_operations` holds after `sync`.
    class_getter permits : Hash(String, Set(String)) do
      definitions.to_h { |role| {role.name, role.operations.to_set} }
    end

    # Decides from the user's live assignments, read once per transaction
    # (`Database::Lease#roles_held`), and the operations of each role in
    # this binary's code: a page whose 50 links ask a policy reads the
    # assignments once.
    private def self.decide(db : Reader | Writer, user_id : Int64, operation : String, type : String?, id : Int64?) : Policy::Decision
      held = held(db, user_id).select { |found| found.resource_type.nil? || (found.resource_type == type && found.resource_id == id) }
      permitting = held.select { |found| permits[found.role]?.try(&.includes?(operation)) }
      decision = if !permitting.empty?
                   Policy::Decision::Allow
                 elsif !held.empty?
                   Policy::Decision::Forbid
                 else
                   Policy::Decision::NotFound
                 end
      event = Trace.event
      if event.recording?
        shown = permitting.empty? ? held : permitting
        event.set("punch.roles", shown.empty? ? "none" : shown.join(", ") { |found| found.resource_type ? found.role : "#{found.role} (global)" })
      end
      decision
    end

    private def self.check_scope(role : R.class, resource : T) : Nil forall R, T
      {% begin %}
        {% raise "#{R} is not a role: a role includes Punch::Role" unless R < Punch::Role %}
        {% scope = R.has_constant?("PUNCH_ROLE_SCOPE") ? parse_type("::#{R}::PUNCH_ROLE_SCOPE").resolve : nil %}
        {% if scope && T == Nil %}
          {% raise "#{R} is held on a resource (#{scope}); pass it with `on:`." %}
        {% elsif !scope && T != Nil %}
          {% raise "#{R} is a global role; it is held without `on:`." %}
        {% elsif scope && T != scope %}
          {% raise "#{R} is held on #{scope}, not on #{T}." %}
        {% end %}
      {% end %}
    end

    private def self.raw(id : TypedID | Int64) : Int64
      id.is_a?(TypedID) ? id.value : id
    end

    private def self.raw(id : Nil) : Nil
    end

    private def self.write(db : Writer, user_id : Int64, role : String, type : String?, id : Int64?,
                           expires_at : Time?, assigned_by : Int64?, now : Time) : Assignment
      expiry = expires_at.try { |time| Stored.dump(time) }
      db.lease.roles_held = nil
      assignment = db.query_one?(<<-SQL, user_id, role, type, id, expiry, assigned_by, Stored.dump(now), name: "Punch::Roles.assign") { |row| read(row) }
        INSERT INTO punch_role_assignments (user_id, role, resource_type, resource_id, expires_at, assigned_by, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (user_id, role, ifnull(resource_type, ''), ifnull(resource_id, 0))
        DO UPDATE SET expires_at = excluded.expires_at, assigned_by = excluded.assigned_by
        RETURNING #{COLUMNS}
        SQL
      assignment || raise("INSERT … RETURNING gave no row")
    end

    private def self.delete(db : Writer, user_id : Int64, role : String, type : String?, id : Int64?) : Assignment?
      db.lease.roles_held = nil
      db.query_one?(<<-SQL, user_id, role, type || "", id || 0_i64, name: "Punch::Roles.revoke") { |row| read(row) }
        DELETE FROM punch_role_assignments
        WHERE user_id = ? AND role = ? AND ifnull(resource_type, '') = ? AND ifnull(resource_id, 0) = ?
        RETURNING #{COLUMNS}
        SQL
    end

    private def self.read(row) : Assignment
      id = row.read(Int64)
      Assignment.new(id, row.read(Int64), row.read(String), row.read(String?), row.read(Int64?),
        row.read(String?).try { |text| Stored.load(Time, text, TABLE, "expires_at", id) }, row.read(Int64?),
        Stored.load(Time, row.read(String), TABLE, "created_at", id))
    end

    # A user was given a role, or its expiry changed. The Command that
    # assigns it publishes this, which is the audit trail.
    struct Assigned
      include Punch::Event

      getter user_id : Int64
      getter role : String
      getter resource_type : String?
      getter resource_id : Int64?
      getter expires_at : Time?
      # Who decided it.
      getter assigned_by : Int64?

      def initialize(@user_id, @role, @resource_type, @resource_id, @expires_at, @assigned_by)
      end

      def self.new(assignment : Assignment) : self
        new(assignment.user_id, assignment.role, assignment.resource_type, assignment.resource_id,
          assignment.expires_at, assignment.assigned_by)
      end
    end

    # A role was taken from a user.
    struct Revoked
      include Punch::Event

      getter user_id : Int64
      getter role : String
      getter resource_type : String?
      getter resource_id : Int64?
      # Who decided it; `nil` when the resource was deleted.
      getter revoked_by : Int64?

      def initialize(@user_id, @role, @resource_type, @resource_id, @revoked_by)
      end

      def self.new(assignment : Assignment, revoked_by : TypedID | Int64?) : self
        by = revoked_by.is_a?(TypedID) ? revoked_by.value : revoked_by
        new(assignment.user_id, assignment.role, assignment.resource_type, assignment.resource_id, by)
      end
    end

    # The tables and the view, as a migration for an app whose users are
    # in *users* (docs/authorization.md).
    module Schema
      TABLES = {
        "punch_role_assignments" => {
          "id" => "INTEGER", "user_id" => "INTEGER", "role" => "TEXT", "resource_type" => "TEXT", "resource_id" => "INTEGER",
          "expires_at" => "TEXT", "assigned_by" => "INTEGER", "created_at" => "TEXT",
        },
        "punch_role_operations" => {"role" => "TEXT", "operation" => "TEXT"},
      }

      def self.sql(users : String = "users") : String
        raise ArgumentError.new("not a table name: #{users.inspect}") unless users.matches?(/\A[a-z_][a-z0-9_]*\z/)
        <<-SQL
          -- Roles (lib/punch/docs/authorization.md): who holds which role, on which
          -- resource, until when; the operations of each role, written
          -- by Punch from the code; and the permissions that follow.
          CREATE TABLE punch_role_assignments (
            id            INTEGER PRIMARY KEY,
            user_id       INTEGER NOT NULL REFERENCES #{users} (id) ON DELETE CASCADE,
            role          TEXT    NOT NULL,
            resource_type TEXT,
            resource_id   INTEGER,
            expires_at    TEXT,
            assigned_by   INTEGER REFERENCES #{users} (id) ON DELETE SET NULL,
            created_at    TEXT    NOT NULL,
            CHECK ((resource_type IS NULL) = (resource_id IS NULL))
          ) STRICT;

          CREATE UNIQUE INDEX punch_role_assignments_unique
            ON punch_role_assignments (user_id, role, ifnull(resource_type, ''), ifnull(resource_id, 0));
          CREATE INDEX punch_role_assignments_by_resource ON punch_role_assignments (resource_type, resource_id);

          CREATE TABLE punch_role_operations (
            role      TEXT NOT NULL,
            operation TEXT NOT NULL,
            PRIMARY KEY (role, operation)
          ) STRICT, WITHOUT ROWID;

          CREATE VIEW punch_permissions (user_id, operation, resource_type, resource_id, role) AS
            SELECT a.user_id, o.operation, a.resource_type, a.resource_id, a.role
            FROM punch_role_assignments a JOIN punch_role_operations o ON o.role = a.role
            WHERE #{LIVE};

          SQL
      end

      # Whether *database* has the table `sync` writes.
      def self.present?(database : Database) : Bool
        database.read do |db|
          !db.query_one?("SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = 'punch_role_operations'", name: "Punch::Roles::Schema.present", &.read(Int64)).nil?
        end
      end

      # What is missing or of another type, one line each.
      def self.problems(database : Database) : Array(String)
        problems = [] of String
        database.read do |db|
          TABLES.each do |table, columns|
            found = db.query_all("SELECT name, type FROM pragma_table_info(?)", table, name: "Punch::Roles::Schema.columns") do |row|
              {row.read(String), row.read(String).upcase}
            end.to_h
            if found.empty?
              problems << "table #{table} is missing; add it with a migration (lib/punch/docs/authorization.md)"
              next
            end
            columns.each do |column, type|
              actual = found[column]?
              problems << "#{table}.#{column} is #{actual || "missing"}, Punch needs #{type}" unless actual == type
            end
          end
          unless db.query_one?("SELECT 1 FROM sqlite_schema WHERE type = 'view' AND name = 'punch_permissions'", name: "Punch::Roles::Schema.view", &.read(Int64))
            problems << "view punch_permissions is missing (lib/punch/docs/authorization.md)"
          end
        end
        problems
      end
    end
  end
end
