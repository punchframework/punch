module Punch::CLI::Commands
  # Lists the app's roles as the code defines them, or with `--user ID`
  # the roles a user holds (docs/authorization.md).
  class RolesList < Command
    command "roles", "List the roles and their operations, or a user's assignments: punch roles [--user ID]"

    struct Definitions
      include Report

      def initialize(@roles : Array(Punch::Roles::Definition))
      end

      def to_text(io : IO) : Nil
        io.puts "No roles: no type includes Punch::Role." if @roles.empty?
        @roles.each do |role|
          io.puts "#{role.name} (#{role.scope ? "on #{role.scope}" : "global"})"
          role.operations.each { |operation| io.puts "  #{operation}" }
        end
      end

      def to_json(json : JSON::Builder) : Nil
        json.object { json.field "roles", @roles }
      end
    end

    struct Assignments
      include Report

      def initialize(@user_id : Int64, @assignments : Array(Punch::Roles::Assignment), @now : Time)
      end

      def to_text(io : IO) : Nil
        io.puts "User #{@user_id} holds no roles." if @assignments.empty?
        @assignments.each do |assignment|
          expiry = assignment.expires_at.try { |time| assignment.expired?(@now) ? "  expired #{AuthCommand.time(time)}" : "  until #{AuthCommand.time(time)}" }
          io.puts "#{assignment.id.to_s.rjust(6)}  #{assignment}#{expiry}  since #{AuthCommand.time(assignment.created_at)}" \
                  "#{assignment.assigned_by.try { |assigner| "  by user #{assigner}" }}"
        end
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "user_id", @user_id
          json.field "assignments", @assignments
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      args = args.dup
      user = AuthCommand.option(args, "--user")
      return user if user.is_a?(Failure)
      return Failure.usage("unexpected_argument", "'punch roles' takes only --user ID.") unless args.empty?
      return Definitions.new(Punch::Roles.definitions.sort_by(&.name)) unless user

      user_id = AuthCommand.id(user, "--user")
      return user_id if user_id.is_a?(Failure)

      AuthCommand.with_database do |database|
        Assignments.new(user_id, database.read { |db| Punch::Roles.assignments(db, user_id: user_id) }, Time.utc)
      end
    end
  end

  # Gives a user a global role on the box: the first operator of a new
  # deployment, before anyone could do it in the app (docs/authorization.md).
  # Roles held on a resource are the app's Commands, which check who may
  # give them and publish `Punch::Roles::Assigned`.
  class RolesAssign < Command
    command "roles:assign", "Give a user a global role: punch roles:assign ROLE --user ID | --email ADDRESS"

    struct Result
      include Report

      def initialize(@assignment : Punch::Roles::Assignment, @verb : String)
      end

      def to_text(io : IO) : Nil
        io.puts "User #{@assignment.user_id} #{@verb} #{@assignment}."
      end

      def to_json(json : JSON::Builder) : Nil
        json.object { json.field "assignment", @assignment }
      end
    end

    def run(args : Array(String)) : Report | Failure
      parsed = RolesAssign.parse(args, self.class.command_name)
      return parsed if parsed.is_a?(Failure)

      id, email, role = parsed
      AuthCommand.with_database do |database|
        database.write do |db|
          user_id = RolesAssign.user(db, id, email)
          next user_id if user_id.is_a?(Failure)
          assignment = Punch::Roles.assign_global(db, user_id, role) || next RolesAssign.unknown(role)
          Result.new(assignment, "now holds")
        rescue Punch::Database::ConstraintError
          # The assignment's foreign key to the app's users table.
          RolesAssign.no_user(id, email)
        end
      end
    end

    # The user (`--user ID` or `--email ADDRESS`) and the role named in
    # *args*, by its stored name or its type's.
    def self.parse(args : Array(String), command : String) : {Int64?, Punch::Email?, String} | Failure
      args = args.dup
      user = AuthCommand.option(args, "--user")
      return user if user.is_a?(Failure)

      email = AuthCommand.option(args, "--email")
      return email if email.is_a?(Failure)
      if args.size != 1 || user.nil? == email.nil?
        return Failure.usage("missing_argument", "Usage: punch #{command} ROLE --user ID | --email ADDRESS")
      end

      user_id = user.try { |text| AuthCommand.id(text, "--user") }
      return user_id if user_id.is_a?(Failure)

      address = email.try { |text| Punch::Email.parse(text) }
      return Failure.usage("invalid_email", "--email must be an email address, got '#{email}'.") if address.is_a?(Punch::Invalid)
      return Failure.new("no_roles", "This app defines no roles.") unless Punch::Roles.used?

      {user_id, address, name(args.first)}
    end

    # The user's ID: as given, or the owner of the address once they
    # verified it. Anyone may claim an address unverified, so it names
    # nobody yet.
    def self.user(db : Punch::Writer, id : Int64?, email : Punch::Email?) : Int64 | Failure
      return id if id

      identity = email.try { |address| Punch::Auth::EmailIdentities.find(db, address) } || return no_user(id, email)
      return identity.user_id if identity.verified?

      Failure.new("unverified_email", "#{email} is not verified: whoever claimed it may not own it. Give the user by ID instead (--user ID) once you know whose account it is; user #{identity.user_id} claimed it.")
    end

    def self.no_user(id : Int64?, email : Punch::Email?) : Failure
      Failure.new("unknown_user", id ? "No user #{id}." : "No user has the address #{email}.")
    end

    # `Accounts::Roles::Operator` and `accounts.roles.operator` name the
    # same role.
    def self.name(text : String) : String
      text.includes?("::") ? text.split("::").map(&.underscore).join(".") : text
    end

    def self.unknown(role : String) : Failure
      globals = Punch::Roles.definitions.select(&.scope.nil?).map(&.name).reject(&.starts_with?("punch."))
      Failure.new("unknown_role", "#{role} is not a global role of this app. Global roles: #{globals.empty? ? "none" : globals.join(", ")}. Roles held on a resource are given by the app's own Commands.")
    end
  end

  # Takes a global role from a user on the box.
  class RolesRevoke < Command
    command "roles:revoke", "Take a global role from a user: punch roles:revoke ROLE --user ID | --email ADDRESS"

    def run(args : Array(String)) : Report | Failure
      parsed = RolesAssign.parse(args, self.class.command_name)
      return parsed if parsed.is_a?(Failure)

      id, email, role = parsed
      return RolesAssign.unknown(role) unless Punch::Roles.global?(role)

      AuthCommand.with_database do |database|
        database.write do |db|
          user_id = RolesAssign.user(db, id, email)
          next user_id if user_id.is_a?(Failure)
          assignment = Punch::Roles.revoke_global(db, user_id, role) ||
                       next Failure.new("not_held", "User #{user_id} does not hold #{role}.")
          RolesAssign::Result.new(assignment, "no longer holds")
        end
      end
    end
  end

  # Shows why a user may or may not run an operation: runs its policy as a
  # request from that user would, with the path parameters given, in a
  # transaction that is rolled back (docs/authorization.md). Only in the
  # derivation build (`-Dpunch_openapi`): one explainer per operation costs
  # compile time that app builds should not pay; the tool's
  # `punch authz:explain` builds and runs it.
  class AuthzExplain < Command
    command "authz:explain", "Why a user may or may not run an operation: punch authz:explain OPERATION --user ID [name=value ...]"

    # The answer as a JSON document, so `punch authz:explain` (the tool,
    # which runs the derivation build) prints it the same way.
    struct Result
      include Report

      def initialize(@document : JSON::Any)
      end

      def self.new(user_id : Int64, params : Hash(String, String), explanation : Punch::Authorization::Explanation,
                   permitting : Array(String), assignments : Array(Punch::Roles::Assignment), now : Time) : self
        document = JSON.build do |json|
          json.object do
            json.field "user_id", user_id
            json.field "params", params
            json.field "explanation", explanation
            json.field "permitted_by", permitting
            json.field "assignments" do
              json.array do
                assignments.each do |assignment|
                  json.object do
                    json.field "assignment", assignment.to_s
                    json.field "expired", assignment.expired?(now)
                  end
                end
              end
            end
          end
        end
        new(JSON.parse(document))
      end

      def to_text(io : IO) : Nil
        user = @document["user_id"]
        explanation = @document["explanation"]
        params = @document["params"].as_h
        where = params.empty? ? "" : " with #{params.join(", ") { |name, value| "#{name}=#{value}" }}"
        io.puts "#{explanation["operation"]} (#{explanation["type"]}) for user #{user}#{where}"
        io.puts "  policy:    #{explanation["policy"]}"
        io.puts "  decision:  #{ANSWERS[explanation["decision"].as_s]}"
        if roles = explanation["roles"].as_s?
          io.puts "  roles:     #{roles == "none" ? "none held there" : roles}"
        end
        permitting = @document["permitted_by"].as_a
        return if permitting.empty?

        io.puts "  permitted by: #{permitting.join(", ")}"
        assignments = @document["assignments"].as_a
        return io.puts("  user #{user} holds no roles") if assignments.empty?

        io.puts "  user #{user} holds:"
        assignments.each { |held| io.puts "    #{held["assignment"]}#{held["expired"].as_bool ? " (expired)" : ""}" }
      end

      ANSWERS = {"allow" => "allow", "forbid" => "forbid (403 forbidden)", "not_found" => "not_found (404 not_found)"}

      def to_json(json : JSON::Builder) : Nil
        @document.to_json(json)
      end
    end

    def run(args : Array(String)) : Report | Failure
      # Every subclass's `run` is compiled wherever commands are dispatched,
      # so only the derivation build reaches the explainers.
      {% if flag?(:punch_openapi) %}
        explain(args, Punch::Authorization.explainers)
      {% else %}
        Failure.new("not_derivation_build", "authz:explain is only in the derivation build; run punch authz:explain.")
      {% end %}
    end

    # :nodoc:
    def explain(args : Array(String), explainers : Hash(String, Punch::Authorization::Explainer)) : Report | Failure
      args = args.dup
      user = AuthCommand.option(args, "--user")
      return user if user.is_a?(Failure)
      return Failure.usage("missing_argument", "'punch authz:explain' needs --user ID.") unless user

      user_id = AuthCommand.id(user, "--user")
      return user_id if user_id.is_a?(Failure)

      operation = args.shift? || return Failure.usage("missing_argument", "'punch authz:explain' needs an operation, by ID (billing.invoices.send) or type.")
      params = parameters(args)
      return params if params.is_a?(Failure)

      found = explainer(operation, explainers)
      return found if found.is_a?(Failure)

      id, explainer = found
      AuthCommand.with_database do |database|
        Punch::Roles.sync(database) if Punch::Roles.used?

        case explained = explainer.call(database, user_id, params)
        in String then Failure.new("cannot_explain", explained)
        in Punch::Authorization::Explanation
          permitting = Punch::Roles.definitions.select(&.operations.includes?(id)).map(&.name)
          assignments = Punch::Roles.used? ? database.read { |db| Punch::Roles.assignments(db, user_id: user_id) } : [] of Punch::Roles::Assignment
          Result.new(user_id, params, explained, permitting, assignments, Time.utc)
        end
      end
    end

    # The path parameters, given as `name=value`.
    private def parameters(args : Array(String)) : Hash(String, String) | Failure
      args.each_with_object({} of String => String) do |arg, params|
        name, equals, value = arg.partition('=')
        return Failure.usage("invalid_parameter", "Path parameters are given as name=value, got '#{arg}'.") if equals.empty? || name.empty?

        params[name] = value
      end
    end

    # The explainer of *operation*, an operation ID or a type's name.
    private def explainer(operation : String, explainers : Hash(String, Punch::Authorization::Explainer)) : {String, Punch::Authorization::Explainer} | Failure
      id = explainers.has_key?(operation) ? operation : operation.split("::").map(&.underscore).join(".")
      if explainer = explainers[id]?
        return {id, explainer}
      end

      known = Punch::Routing.routes.find { |route| route.operation_id == id }
      return Failure.new("no_policy", "#{operation} has no policy#{known.public ? ": it is public" : ""}.") if known

      Failure.new("unknown_operation", "No operation #{operation}; 'routes' lists them.")
    end
  end
end
