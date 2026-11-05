module Punch::Upload
  # What Punch answers below `PREFIX`, ahead of the app's routes: the
  # check (`POST /_punch/uploads/check`), and with local storage the
  # signed `PUT` and `GET` of files. Outside any transaction: the check
  # asks the storage, which may take a while, and holds the writer only
  # for the state change at the end.
  module Endpoint
    # The largest check body: `{"ticket": "upl_…"}`.
    BODY_LIMIT = 1024

    # Checks per client address: a browser checks once per file, and each
    # check costs up to four storage requests. Made on first use, so apps
    # without uploads have no such limit.
    class_getter limiter : RateLimits::Limiter { RateLimits::Limiter.new("uploads.check.ip", 60, per: 1.minute, by: "ip") }

    # The response for a request below `PREFIX`, or `nil` for any other.
    def self.respond(context : HTTP::Context, database : Database) : HTTP::Response?
      request = context.request
      path = request.path
      return unless path.starts_with?(PREFIX)
      return unless Upload.used?

      if path == CHECK_PATH
        traced(context, "POST", CHECK_PATH)
        return HTTP::Response.problem(:method_not_allowed, context).tap { |response| response.headers["Allow"] = "POST" } unless request.method == "POST"
        return refuse(context, :forbidden, "cross_origin_request") unless HTTP::CrossOrigin.allowed?(request, context.config.trusted_origins)
        if limited = RateLimits.limited(Endpoint.limiter, RateLimits.ip_key(context.client_ip), context)
          return RateLimits.apply(RateLimits.respond(limited, context), context)
        end

        RateLimits.apply(check(context, database), context)
      elsif path.starts_with?(LOCAL_PATH) && (storage = Upload.storage?.as?(LocalStorage))
        local(context, storage, path[LOCAL_PATH.size..])
      end
    end

    private def self.traced(context : HTTP::Context, method : String, route : String) : Nil
      span = context.span
      return unless span.recording?

      span.name = "#{method} #{route}"
      span.set("http.route", route)
      span.set("punch.surface", "upload")
    end

    # Answers the check: the ticket from the body, then `Upload.check`.
    def self.check(context : HTTP::Context, database : Database) : HTTP::Response
      body = context.read_body(BODY_LIMIT)
      return refuse(context, :payload_too_large, "payload_too_large") if body.is_a?(HTTP::BodyTooLarge)

      ticket = begin
        JSON.parse(body).as_h?.try(&.["ticket"]?).try(&.as_s?).try { |text| Ticket.parse(text) }
      rescue JSON::ParseException
        nil
      end
      return refuse(context, :unprocessable_entity, "invalid_upload") unless ticket.is_a?(Ticket)

      case result = Upload.check(database, ticket)
      in Checked
        context.span.set("punch.upload.kind", result.kind)
        HTTP::Response.json(:ok, result.to_json)
      in Refused
        refuse(context, result.status, result.code)
      end
    end

    private def self.refuse(context : HTTP::Context, status : ::HTTP::Status, code : String) : HTTP::Response
      context.span.set("punch.outcome", code)
      HTTP::Response.problem(status, context, code)
    end

    # The signed `PUT` and `GET` of local storage, as a bucket answers
    # them: the signature, expiry, size, and type are checked; a file is
    # served with its type, as a download unless it is safe to show, and
    # sandboxed.
    private def self.local(context : HTTP::Context, storage : LocalStorage, encoded : String) : HTTP::Response
      request = context.request
      object = URI.decode(encoded)
      traced(context, request.method, "#{LOCAL_PATH}*")
      return refuse(context, :not_found, "not_found") unless Storage.valid_object?(object)

      method = request.method == "HEAD" ? "GET" : request.method
      params = storage.verify(method, object, request.query_params, Time.utc) || return refuse(context, :forbidden, "forbidden")
      case method
      when "PUT" then local_put(context, storage, object, params)
      when "GET" then local_get(context, storage, object, params)
      else            HTTP::Response.problem(:method_not_allowed, context)
      end
    end

    private def self.local_put(context : HTTP::Context, storage : LocalStorage, object : String, params : Hash(String, String)) : HTTP::Response
      request = context.request
      size = params["size"]?.try(&.to_i64?)
      type = params["type"]?
      return refuse(context, :forbidden, "forbidden") unless size && type && Storage.pending?(object)
      # Without a length (a chunked body), `write` takes exactly `size` bytes or nothing.
      return refuse(context, :forbidden, "forbidden") unless request.content_length.in?(nil, size) && request.headers["Content-Type"]? == type
      return refuse(context, :bad_request, "bad_request") unless storage.write(object, request.body || IO::Memory.new, size, type)

      HTTP::Response.new(:ok, "", ::HTTP::Headers{"ETag" => "\"\""})
    end

    private def self.local_get(context : HTTP::Context, storage : LocalStorage, object : String, params : Hash(String, String)) : HTTP::Response
      found = Storage.pending?(object) ? nil : storage.file(object)
      return refuse(context, :not_found, "not_found") unless found

      path, type, disposition = found
      headers = ::HTTP::Headers{
        "Content-Type"            => type,
        "Content-Disposition"     => params["download"]?.try { |name| Upload.attachment(name) } || disposition,
        "Content-Security-Policy" => "default-src 'none'; sandbox",
        "Cache-Control"           => "private, max-age=3600",
      }
      HTTP::Response.new(:ok, ::File.read(path), headers)
    end
  end
end
