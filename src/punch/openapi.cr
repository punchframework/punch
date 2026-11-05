require "./json_schema"
require "./routing"

module Punch
  # The OpenAPI 3.2 document of an application, derived from its operations:
  # paths and methods from the route table, parameters and request bodies
  # from inputs, responses from the types `call` really returns, and every
  # schema from `Punch::JSONSchema`.
  #
  # Derivation is compiled only into the build `punch openapi` makes
  # (`-Dpunch_openapi`); the application embeds the committed
  # `openapi.json` instead (`Punch.openapi_document`).
  module OpenAPI
    VERSION = "3.2.0"

    PROBLEM            = "Punch.Problem"
    SESSION            = "session"
    BEARER             = "bearer"
    VALIDATION_PROBLEM = "Punch.ValidationProblem"

    # The document, and where each part came from, for descriptions.
    record Derived, document : JSON::Any, types : Hash(String, String),
      fields : Hash(String, Hash(String, String)), operations : Hash(String, String) do
      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "document", document
          json.field "types", types
          json.field "fields", fields
          json.field "operations", operations
        end
      end
    end

    # Derives the document of every operation in this binary.
    def self.derive(title : String, version : String) : Derived
      registry = JSONSchema::Registry.new("#/components/schemas/")
      routes = Routing.routes.to_h { |route| {route.operation, route} }
      operations = {} of String => {Routing::Route, JSON::Any}
      {% for op in Punch::Operation.all_subclasses.reject { |op| op.abstract? || op < Punch::Page || op.annotation(Punch::Unlisted) } %}
        %route = routes[{{ op.stringify }}]
        operations[{{ op.stringify }}] = { %route, operation({{ op.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, %route, registry) }
      {% end %}

      paths = {} of String => Hash(String, JSON::Any)
      operations.each_value do |route, entry|
        path = route.template.gsub(/:(\w+)/) { "{#{$1}}" }
        (paths[path] ||= {} of String => JSON::Any)[route.method.downcase] = entry
      end
      schemas = registry.definitions
      schemas[PROBLEM] = problem_schema
      schemas[VALIDATION_PROBLEM] = validation_problem_schema
      components = {"schemas" => JSON::Any.new(schemas.keys.sort!.to_h { |name| {name, schemas[name]} })}
      if operations.each_value.any? { |_, entry| entry["security"]? }
        components["securitySchemes"] = security_schemes
      end
      document = {
        "openapi"    => JSON::Any.new(VERSION),
        "info"       => JSON::Any.new({"title" => JSON::Any.new(title), "version" => JSON::Any.new(version)}),
        "paths"      => JSON::Any.new(paths.keys.sort!.to_h { |path| {path, sorted_methods(paths[path])} }),
        "components" => JSON::Any.new(components),
      }
      Derived.new(JSON::Any.new(document), registry.type_names, registry.field_names,
        operations.to_h { |name, (route, _)| {route.operation_id, name} })
    end

    # One operation's entry. Only what depends on the operation's types is
    # generic; the rest is built once for all operations (`entry`), which
    # keeps the compiler's work per operation small.
    def self.operation(op : O.class, route : Routing::Route, registry : JSONSchema::Registry) : JSON::Any forall O
      {% begin %}
      {% security = "none" %}
      {% stubs = parse_type("::#{O}::PunchCallExtras").resolve.type_vars %}
      {% hashes = stubs.includes?(Punch::Auth::PasswordCheck) %}
      {% for type in stubs %}
        {% security = type.union? ? "optional" : "required" unless type == Punch::Auth::Authentication || type == Punch::Auth::PasswordCheck || type == Punch::Auth::SecondFactorCheck %}
      {% end %}
      {% if O < Punch::Command %}
        {% for ivar in parse_type("::#{O}::Input").resolve.instance_vars %}
          {% hashes = true if ivar.type == Punch::Auth::NewPassword || (ivar.type.union? && ivar.type.union_types.includes?(Punch::Auth::NewPassword)) %}
        {% end %}
      {% end %}
      fields = JSONSchema.fields(O::Input, registry)
      command = {{ O < Punch::Command }}
      body = command && fields.any? { |field| !field.path } ? registry.schema(O::Input) : nil
      handle = {% if O < Punch::Command %} Pointer(Punch::Writer).null {% else %} Pointer(Punch::Reader).null {% end %}
      # The declared return type of `call`; without one, the inferred type.
      responses = {% if O.has_constant?("PunchDeclaredResult") %} responses(O::PunchDeclaredResult, registry) {% else %} responses(typeof(O.new.call(Pointer(O::Input).null.value, handle.value{% for stub in stubs %}, Pointer({{ stub.stringify.gsub(::Punch::NAME_STARTS, "::").id }}).null.value{% end %})), registry) {% end %}
      limits = {% if O.has_constant?("PUNCH_RATE_LIMITS") %} O::PUNCH_RATE_LIMITS.to_a.map(&.to_s) {% else %} [] of String {% end %}
      entry(route, fields, command, body, responses, registry, {{ security }}, limits, {{ hashes }}, {{ O.has_constant?("PunchPolicy") }},
        Routing.idempotency(O), {{ O.has_constant?("PunchPolicy") && parse_type("::#{O}::PunchPolicy").resolve < Punch::Policy::RecentAuthentication }})
      {% end %}
    end

    private def self.entry(route : Routing::Route, fields : Array(JSONSchema::Field), command : Bool, body : JSON::Any?,
                           responses : Hash(String, JSON::Any), registry : JSONSchema::Registry, security : String,
                           limits : Array(String) = [] of String, hashes : Bool = false, policy : Bool = false,
                           idempotency : Symbol = :none, recent : Bool = false) : JSON::Any
      parameters = parameters(fields, command)
      parameters << IF_NONE_MATCH if responses.has_key?("304")
      entry = {"operationId" => JSON::Any.new(route.operation_id)}
      # Tagged by slice, the first segment, so the document groups as the
      # app's directories do (docs/structure.md).
      tag = route.operation_id.partition('.').first
      entry["tags"] = JSON::Any.new([JSON::Any.new(tag)]) if route.operation_id.includes?('.')
      keyed(parameters, responses, command, idempotency, security, registry)
      entry["parameters"] = JSON::Any.new(parameters) unless parameters.empty?
      if body
        entry["requestBody"] = JSON::Any.new({
          "required" => JSON::Any.new(fields.any? { |field| field.required && !field.path }),
          "content"  => content("application/json", body),
        })
      end
      unless fields.empty?
        validation = JSONSchema.object({"$ref" => JSON::Any.new(registry.prefix + VALIDATION_PROBLEM)})
        responses["422"] = (own = responses["422"]?) ? with_alternative(own, validation) : problem_response(validation)
      end
      secure(entry, responses, security, registry)
      refusals(responses, command, policy, recent, registry)
      limited(responses, limits, registry) unless limits.empty?
      busy(responses, registry) if hashes
      responses["default"] = problem_response(JSONSchema.object({"$ref" => JSON::Any.new(registry.prefix + PROBLEM)}))
      entry["responses"] = JSON::Any.new(responses)
      JSON::Any.new(entry)
    end

    # Path and query parameters; a Command's other fields are its body.
    private def self.parameters(fields : Array(JSONSchema::Field), command : Bool) : Array(JSON::Any)
      fields.compact_map do |field|
        next if command && !field.path
        hash = {
          "name"   => JSON::Any.new(field.name),
          "in"     => JSON::Any.new(field.path ? "path" : "query"),
          "schema" => non_null(field.schema),
        }
        hash["required"] = JSON::Any.new(true) if field.required || field.path
        if field.nested
          # `filter[status]=paid`: each field of the nested input in brackets.
          hash["style"] = JSON::Any.new("deepObject")
          hash["explode"] = JSON::Any.new(true)
        end
        JSON::Any.new(hash)
      end
    end

    # Signed in by the session cookie or a bearer token, else 401; `{}`
    # admits anonymous requests where the actor is optional.
    private def self.secure(entry : Hash(String, JSON::Any), responses : Hash(String, JSON::Any), security : String,
                            registry : JSONSchema::Registry) : Nil
      return if security == "none"

      schemes = [JSON::Any.new({SESSION => JSON::Any.new([] of JSON::Any)}), JSON::Any.new({BEARER => JSON::Any.new([] of JSON::Any)})]
      schemes << JSON::Any.new({} of String => JSON::Any) if security == "optional"
      entry["security"] = JSON::Any.new(schemes)
      responses["401"] ||= problem_response(JSONSchema.object({"allOf" => JSON::Any.new([
        JSONSchema.object({"$ref" => JSON::Any.new(registry.prefix + PROBLEM)}),
        JSONSchema.object({"properties" => JSON::Any.new({"code" => JSONSchema.object({"const" => JSON::Any.new("unauthenticated")})})}),
      ])}))
    end

    # A problem with *code* that Punch answers with *status*, as one more
    # alternative where the operation's results have that status too.
    # Every Command refuses another site's page; a policy forbids, or hides
    # what the actor must not know exists, and may ask for a recent
    # authentication.
    private def self.refusals(responses : Hash(String, JSON::Any), command : Bool, policy : Bool, recent : Bool,
                              registry : JSONSchema::Registry) : Nil
      coded(responses, "403", "cross_origin_request", registry) if command
      return unless policy

      coded(responses, "403", "forbidden", registry)
      coded(responses, "404", "not_found", registry)
      coded(responses, "403", "reauthentication_required", registry) if recent
    end

    private def self.coded(responses : Hash(String, JSON::Any), status : String, code : String, registry : JSONSchema::Registry) : Nil
      schema = JSONSchema.object({"allOf" => JSON::Any.new([
        JSONSchema.object({"$ref" => JSON::Any.new(registry.prefix + PROBLEM)}),
        JSONSchema.object({"properties" => JSON::Any.new({"code" => JSONSchema.object({"const" => JSON::Any.new(code)})})}),
      ])})
      responses[status] = (own = responses[status]?) ? with_alternative(own, schema) : problem_response(schema)
      sorted = responses.to_a.sort_by!(&.[0])
      responses.clear.merge!(sorted.to_h)
    end

    # The `Idempotency-Key` header of a Command that takes keys.
    private def self.idempotency_key(required : Bool) : JSON::Any
      JSON::Any.new({
        "name"        => JSON::Any.new(IdempotencyKeys::HEADER),
        "in"          => JSON::Any.new("header"),
        "required"    => JSON::Any.new(required),
        "description" => JSON::Any.new("Names this attempt, so it can be retried safely: a request with the same key and the same " \
                                       "path and body gets the first answer again, marked `#{IdempotencyKeys::REPLAYED_HEADER}: true`, " \
                                       "and the operation does not run twice. A key is kept for at least " \
                                       "#{IdempotencyKeys::MINIMUM_RETENTION.total_hours.to_i} hours; reuse it only to retry the same request. " \
                                       "1 to 255 visible ASCII characters, bare or as a quoted string."),
        "schema" => JSON.parse(%({"type": "string", "minLength": 1, "maxLength": 257})),
      })
    end

    # The answers about idempotency keys: 400 for a key that does not
    # parse, is missing where required, or is sent where none is taken;
    # 422 for a key reused for another request.
    private def self.keyed(parameters : Array(JSON::Any), responses : Hash(String, JSON::Any), command : Bool, idempotency : Symbol,
                           security : String, registry : JSONSchema::Registry) : Nil
      return unless command

      if idempotency == :none
        coded(responses, "400", "idempotency_key_not_accepted", registry)
        return
      end
      parameters << idempotency_key(idempotency == :required)
      coded(responses, "400", "invalid_idempotency_key", registry)
      coded(responses, "400", "idempotency_key_required", registry) if idempotency == :required
      coded(responses, "400", "idempotency_key_not_accepted", registry) if security == "optional"
      coded(responses, "422", "idempotency_key_reused", registry)
    end

    RATE_LIMITED = JSON.parse(<<-JSON)
      {"properties": {"code": {"const": "rate_limited"},
        "retry_after": {"type": "integer", "format": "int32", "description": "Seconds until a request can succeed."},
        "limit": {"type": "string", "description": "The name of the limit that refused the request."}},
       "required": ["retry_after", "limit"]}
      JSON

    # 429 on a rate-limited operation, naming its limits, with
    # `Retry-After`.
    private def self.limited(responses : Hash(String, JSON::Any), limits : Array(String), registry : JSONSchema::Registry) : Nil
      schema = JSONSchema.object({"allOf" => JSON::Any.new([
        JSONSchema.object({"$ref" => JSON::Any.new(registry.prefix + PROBLEM)}),
        RATE_LIMITED,
      ])})
      response = problem_response(schema).as_h
      response["description"] = JSON::Any.new("Too Many Requests. Limits: #{limits.join("; ")}.")
      response["headers"] = JSON.parse(%({"Retry-After": {"description": "Seconds until a request can succeed.", "schema": {"type": "integer"}}}))
      responses["429"] = JSON::Any.new(response)
      sorted = responses.to_a.sort_by!(&.[0])
      responses.clear.merge!(sorted.to_h)
    end

    # 503 on a Command that hashes or checks a password, when the hasher's
    # queue is full, with `Retry-After`.
    private def self.busy(responses : Hash(String, JSON::Any), registry : JSONSchema::Registry) : Nil
      schema = JSONSchema.object({"allOf" => JSON::Any.new([
        JSONSchema.object({"$ref" => JSON::Any.new(registry.prefix + PROBLEM)}),
        JSONSchema.object({"properties" => JSON::Any.new({"code" => JSONSchema.object({"const" => JSON::Any.new("passwords_busy")})})}),
      ])})
      response = problem_response(schema).as_h
      response["description"] = JSON::Any.new("Service Unavailable: too many passwords are being checked at once.")
      response["headers"] = JSON.parse(%({"Retry-After": {"description": "Seconds until a request can succeed.", "schema": {"type": "integer"}}}))
      responses["503"] = JSON::Any.new(response)
      sorted = responses.to_a.sort_by!(&.[0])
      responses.clear.merge!(sorted.to_h)
    end

    # A result type's own 422 and a rejected input share the status, so
    # either body may come.
    private def self.with_alternative(response : JSON::Any, schema : JSON::Any) : JSON::Any
      own = response["content"]["application/problem+json"]["schema"]
      alternatives = own["oneOf"]?.try(&.as_a) || [own]
      return response if alternatives.includes?(schema)

      hash = response.as_h.dup
      hash["content"] = content("application/problem+json", JSONSchema.object({"oneOf" => JSON::Any.new(alternatives + [schema])}))
      JSON::Any.new(hash)
    end

    # The responses of a result type, one per status; members that share a
    # status are alternatives.
    def self.responses(type : T.class, registry : JSONSchema::Registry) : Hash(String, JSON::Any) forall T
      members = [] of {Int32, JSON::Any?, Bool}
      {% for member in T.union_types %}
        members << member({{ member.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, registry)
      {% end %}
      responses = {} of String => JSON::Any
      members.group_by(&.[0]).to_a.sort_by!(&.[0]).each do |status, group|
        response = {"description" => JSON::Any.new(::HTTP::Status.new(status).description || status.to_s)}
        schemas = group.compact_map(&.[1]).uniq!
        unless schemas.empty?
          schema = schemas.size == 1 ? schemas.first : JSONSchema.object({"oneOf" => JSON::Any.new(schemas)})
          response["content"] = content(group.first[2] ? "application/problem+json" : "application/json", schema)
        end
        responses[status.to_s] = JSON::Any.new(response)
      end
      {% if T.union_types.any? { |member| member < Punch::HTTP::Versioned } %}
        conditional(responses)
      {% end %}
      responses
    end

    IF_NONE_MATCH = JSON.parse(<<-JSON)
      {"name": "If-None-Match", "in": "header", "schema": {"type": "string"},
       "description": "ETag of a copy the client has; answered with 304 while it is current."}
      JSON

    # A versioned result (`Punch::HTTP::Versioned`): its 200 carries an `ETag`,
    # and a request naming the current one gets 304 without a body.
    private def self.conditional(responses : Hash(String, JSON::Any)) : Nil
      etag = JSON::Any.new({"ETag" => JSON::Any.new({
        "description" => JSON::Any.new("Weak entity tag of the result's version; send it back in If-None-Match."),
        "schema"      => JSONSchema.object({"type" => JSON::Any.new("string")}),
      })})
      if ok = responses["200"]?
        responses["200"] = JSON::Any.new(ok.as_h.merge({"headers" => etag}))
      end
      responses["304"] = JSON::Any.new({"description" => JSON::Any.new("Not Modified: If-None-Match names the current version."), "headers" => etag})
      sorted = responses.to_a.sort_by!(&.[0])
      responses.clear.merge!(sorted.to_h)
    end

    # Status, schema (nil without a body), and whether it is a problem.
    def self.member(type : T.class, registry : JSONSchema::Registry) : {Int32, JSON::Any?, Bool} forall T
      {% if T == Nil %}
        {204, nil, false}
      {% elsif T == Punch::Rejection || T < Punch::Database::Violation %}
        # Answered like a rejected input.
        {422, JSONSchema.object({"$ref" => JSON::Any.new(registry.prefix + VALIDATION_PROBLEM)}), true}
      {% else %}
        {% status = T.annotation(Punch::Status) ? T.annotation(Punch::Status)[0] : 200 %}
        {% if status < 400 %}
          { {{ status }}, registry.schema(T), false }
        {% else %}
          parts = [
            JSONSchema.object({"$ref" => JSON::Any.new(registry.prefix + PROBLEM)}),
            JSONSchema.object({"properties" => JSON::Any.new({"code" => JSONSchema.object({"const" => JSON::Any.new({{ ((T.type_vars.empty? && T.has_constant?("PROBLEM_CODE")) ? T.constant("PROBLEM_CODE") : T.name(generic_args: false).split("::").last.underscore) }})})})}),
          ]
          {% if T.instance_vars.size > 0 %}
            parts << registry.schema(T)
          {% end %}
          { {{ status }}, JSONSchema.object({"allOf" => JSON::Any.new(parts)}), true }
        {% end %}
      {% end %}
    end

    # A parameter is absent or has a value; it is never `null`.
    private def self.non_null(schema : JSON::Any) : JSON::Any
      hash = schema.as_h
      if types = hash["type"]?.try(&.as_a?)
        rest = types.reject(&.== "null")
        return JSONSchema.set(schema, "type", rest.size == 1 ? rest.first : JSON::Any.new(rest))
      end
      if alternatives = hash["anyOf"]?.try(&.as_a)
        rest = alternatives.reject { |alternative| alternative["type"]? == "null" }
        return rest.first if rest.size == 1 && hash.size == 1
      end
      schema
    end

    private def self.problem_response(schema : JSON::Any) : JSON::Any
      JSON::Any.new({"description" => JSON::Any.new("Problem Details (RFC 9457)"), "content" => content("application/problem+json", schema)})
    end

    private def self.content(media_type : String, schema : JSON::Any) : JSON::Any
      JSON::Any.new({media_type => JSON::Any.new({"schema" => schema})})
    end

    METHOD_ORDER = %w[get post put patch delete]

    private def self.sorted_methods(methods : Hash(String, JSON::Any)) : JSON::Any
      JSON::Any.new(methods.keys.sort_by! { |method| METHOD_ORDER.index(method) || 99 }.to_h { |method| {method, methods[method]} })
    end

    # The session cookie and API tokens (docs/auth.md).
    private def self.security_schemes : JSON::Any
      JSON.parse(<<-JSON)
        {
          "#{SESSION}": {"type": "apiKey", "in": "cookie", "name": "#{Auth::COOKIE}", "description": "A browser session, set by signing in."},
          "#{BEARER}": {"type": "http", "scheme": "bearer", "description": "An API token: `Authorization: Bearer <token>`."}
        }
        JSON
    end

    private def self.problem_schema : JSON::Any
      JSON.parse(<<-JSON)
        {
          "type": "object",
          "description": "A problem (RFC 9457). `type` is about:blank, so `title` is the status phrase; `code` names the problem; `detail`, where present, is its message for people in the response's `Content-Language`.",
          "properties": {
            "type": {"type": "string", "format": "uri-reference"},
            "title": {"type": "string"},
            "status": {"type": "integer", "format": "int32"},
            "code": {"type": "string"},
            "detail": {"type": "string"},
            "request_id": {"type": "string"}
          },
          "required": ["type", "title", "status", "code"]
        }
        JSON
    end

    private def self.validation_problem_schema : JSON::Any
      JSON.parse(<<-JSON)
        {
          "allOf": [
            {"$ref": "#/components/schemas/#{PROBLEM}"},
            {
              "type": "object",
              "properties": {
                "code": {"const": "invalid_input"},
                "errors": {
                  "type": "array",
                  "items": {
                    "type": "object",
                    "properties": {
                      "path": {"type": "array", "items": {"type": ["string", "integer"]}},
                      "code": {"type": "string"},
                      "params": {"type": "object", "additionalProperties": {"type": ["string", "integer", "number", "boolean"]}},
                      "message": {"type": "string"}
                    },
                    "required": ["path", "code", "params"]
                  }
                }
              },
              "required": ["errors"]
            }
          ]
        }
        JSON
    end
  end

  # The committed `openapi.json`, embedded at compile time, for
  # `Routing::Router.new(database, openapi: Punch.openapi_document)`; `nil` when the
  # file does not exist yet. *path* is relative to where the compiler runs.
  macro openapi_document(path = "openapi.json")
    {{ read_file?(path) }}
  end
end
