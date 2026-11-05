require "./page"

module Punch
  # A form a Command refused: what the browser sent and why it was refused.
  # The page that holds the form is rendered again with it, and the form
  # for the same Command and path shows the values and the errors
  # (docs/views.md).
  struct Submission
    # The Command, such as `Billing::Customers::Create`.
    getter command : String
    # The path the form was sent to, which tells apart forms for one
    # Command on one page (a delete button per row).
    getter path : String
    getter form : URI::Params
    # Errors at fields, and at the empty path for the form as a whole.
    getter errors : Array(Rejection::FieldError)
    getter status : ::HTTP::Status

    def initialize(@command : String, @path : String, @form : URI::Params, @errors : Array(Rejection::FieldError), @status : ::HTTP::Status)
    end

    # Whether this is the submission of the form for *command* at *path*.
    def for?(command : String, path : String) : Bool
      @command == command && @path == path
    end
  end

  # Answers a browser's form the way Turbo Drive expects: a `303 See Other`
  # after success, and the page that holds the form, with the errors, after
  # a refusal.
  module Submissions
    # The input did not parse, or the Command refused it (a rejection or a
    # violation): 422 and the form again.
    def self.rejected(page : P.class, command : C.class, rejection : Rejection, form : URI::Params,
                      context : HTTP::Context, params : Hash(String, String), database : Database) : HTTP::Response forall P, C
      context.span.set("punch.outcome", "invalid_input")
      context.span.set("punch.input.errors", rejection.errors.size)
      again(P, C, form, rejection.errors, :unprocessable_entity, context, params, database)
    end

    # The Command ran. Success redirects (`Page.redirect`, by default to
    # the page that holds the form); a rejection or violation shows the
    # form again with its field errors; any other result from 400 on with
    # that status and the result's code as the form's error.
    #
    # Success answers Turbo Stream actions instead when the page has them
    # for the result (`Page.stream`) and the request names
    # `text/vnd.turbo-stream.html`. *within* is the Command's transaction
    # when this runs inside it (a stored idempotent answer): the stream
    # then renders there, seeing the Command's writes.
    def self.respond(page : P.class, command : C.class, result : T, form : URI::Params,
                     context : HTTP::Context, params : Hash(String, String), database : Database,
                     within : Writer? = nil) : HTTP::Response forall P, C, T
      {% if T.union? %}
        case result
        {% for member in T.union_types %}
          in {{ member.stringify.gsub(::Punch::NAME_STARTS, "::").id }} then respond(P, C, result, form, context, params, database, within)
        {% end %}
        end
      {% elsif T == Punch::Auth::Unauthenticated %}
        Pages.unauthenticated(context)
      {% elsif T == Punch::Policy::Refused %}
        context.span.set("punch.outcome", result.code)
        again(P, C, form, [Rejection::FieldError.new(Rejection::Path.new, result.code)], result.status, context, params, database)
      {% elsif T == Punch::Rejection %}
        rejected(P, C, result, form, context, params, database)
      {% elsif T < Punch::Database::Violation %}
        context.span.set("punch.violation", result.constraint)
        rejected(P, C, result.rejection, form, context, params, database)
      {% else %}
        {% status_annotation = T.annotation(Punch::Status) %}
        {% status = status_annotation ? status_annotation[0] : (T == Nil ? 204 : 200) %}
        {% code = T == Nil ? "no_content" : ((T.type_vars.empty? && T.has_constant?("PROBLEM_CODE")) ? T.constant("PROBLEM_CODE") : T.name(generic_args: false).split("::").last.underscore) %}
        context.span.set("punch.outcome", {{ code }})
        {% if status < 400 %}
          {% if P.class.methods.any? { |method| method.name == "stream" } %}
            if HTTP::Accept.names?(context.request.headers["Accept"]?, STREAM) && (stream = P.stream(result))
              return answer_stream(P, stream, context, database, within)
            end
          {% end %}
          target = P.redirect(result) || Href.new(Routing.fill(Routing.template(P), params), P.name)
          # An agent goes on to the next page's markdown.
          location = context.markdown? ? Routing.markdown_url(target) : target.url
          HTTP::Response.new(:see_other, "", ::HTTP::Headers{"Location" => location})
        {% else %}
          again(P, C, form, [Rejection::FieldError.new(Rejection::Path.new, {{ code }})], ::HTTP::Status.new({{ status }}), context, params, database)
        {% end %}
      {% end %}
    end

    # The media type of Turbo Stream actions.
    STREAM = "text/vnd.turbo-stream.html"

    # Renders *stream* for the page's actor, so its forms and links ask
    # their policies: in the Command's transaction (*within*), or in a
    # read transaction after it committed.
    private def self.answer_stream(page : P.class, stream : TurboStream, context : HTTP::Context, database : Database, within : Writer?) : HTTP::Response forall P
      span = context.span.child("render")
      if span.recording?
        span.set("punch.view", "Punch::TurboStream")
        span.set("punch.stream.actions", stream.changes.size)
      end
      html = begin
        {% begin %}
          {% actor = nil %}
          {% for type in parse_type("::#{P}::PunchCallExtras").resolve.type_vars %}
            {% members = type.union? ? type.union_types.reject(&.==(Nil)) : [type] %}
            {% actor = members[0] if members.size == 1 && members[0] < Punch::Auth::Actor %}
          {% end %}
          {% if actor %}
            if writer = within
              stream_for({{ actor.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, stream, context, writer, Reader.new(writer.lease))
            else
              database.read { |reader| stream_for({{ actor.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, stream, context, reader, reader) }
            end
          {% else %}
            stream.render(nil, context.locale)
          {% end %}
        {% end %}
      ensure
        span.finish
      end
      HTTP::Response.turbo_stream(html)
    end

    private def self.stream_for(actor : A.class, stream : TurboStream, context : HTTP::Context, db : Reader | Writer, reader : Reader) : SafeHTML forall A
      principal = Auth.authenticate(context, db, Time.utc)
      viewer = principal.is_a?(Auth::Principal) ? A.load(principal, db) : nil
      stream.render(Policy::Authorizer.new(viewer, reader), context.locale)
    end

    private def self.again(page : P.class, command : C.class, form : URI::Params, errors : Array(Rejection::FieldError), status : ::HTTP::Status,
                           context : HTTP::Context, params : Hash(String, String), database : Database) : HTTP::Response forall P, C
      context.submission = Submission.new(C.name, context.request.path, form, errors, status)
      {% unless P.annotation(Punch::AgentReadable) %}
        # An agent that reads markdown sent it, from a page that holds no
        # markdown of this form: the refusal as a problem in markdown.
        if context.markdown?
          code = errors.find(&.path.empty?).try(&.code) || "invalid_input"
          return Pages.problem(status, code, context, errors.reject(&.path.empty?))
        end
      {% end %}
      Routing.endpoint(P, context, params, database)
    end
  end
end
