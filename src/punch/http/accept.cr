module Punch::HTTP
  # Content negotiation by the `Accept` header (RFC 9110, 12.5.1).
  module Accept
    WEIGHT = /\A(?:0(?:\.\d{0,3})?|1(?:\.0{0,3})?)\z/

    # The offer the client prefers among *offers*, such as
    # `["application/json", "text/html"]`: highest `q` first, then the most
    # specific matching range (`text/html` over `text/*` over `*/*`), then
    # the order of *offers*. Without a header, or when the client accepts
    # none of them, the first offer: a server may ignore `Accept`.
    #
    # A browser (`text/html,…,*/*;q=0.8`) gets HTML; `curl` and `fetch`
    # (`*/*`) get the first offer.
    def self.preferred(header : String?, offers : Array(String)) : String
      ranges = header.try { |value| parse(value) }
      return offers.first if ranges.nil? || ranges.empty?

      best = offers.first
      best_rank = {0.0, 0}
      offers.each do |offer|
        rank = rank(offer, ranges)
        if rank[0] > 0 && (rank[0] > best_rank[0] || (rank[0] == best_rank[0] && rank[1] > best_rank[1]))
          best, best_rank = offer, rank
        end
      end
      best
    end

    # Whether the client names *type* itself, with a weight above 0, not
    # only through a range such as `*/*`. Turbo names
    # `text/vnd.turbo-stream.html` for forms; a browser's `*/*` must not
    # get a stream.
    def self.names?(header : String?, type : String) : Bool
      return false unless header

      main, _, sub = type.partition('/')
      parse(header).any? { |(range_type, range_subtype, weight)| range_type == main && range_subtype == sub && weight > 0 }
    end

    # `{q, specificity}` of the range that matches *offer* most specifically.
    private def self.rank(offer : String, ranges : Array({String, String, Float64})) : {Float64, Int32}
      type, _, subtype = offer.partition('/')
      found = {0.0, 0}
      ranges.each do |range_type, range_subtype, weight|
        specificity = if range_type == type && range_subtype == subtype
                        3
                      elsif range_type == type && range_subtype == "*"
                        2
                      elsif range_type == "*" && range_subtype == "*"
                        1
                      else
                        next
                      end
        found = {weight, specificity} if specificity > found[1]
      end
      found
    end

    # Says that *response* depends on the `Accept` header, for a cache that
    # keeps it: appended to a `Vary` it has, once.
    def self.vary(response : HTTP::Response) : HTTP::Response
      headers = response.headers
      listed = headers["Vary"]?.try(&.split(',').any? { |name| name.strip.compare("Accept", case_insensitive: true).zero? })
      headers.add("Vary", "Accept") unless listed
      response
    end

    # Media ranges as `{type, subtype, q}`, lowercased. A malformed range
    # or weight is skipped; a header that is not UTF-8 has none, since a
    # regular expression raises on such text.
    def self.parse(header : String) : Array({String, String, Float64})
      return [] of {String, String, Float64} unless header.valid_encoding?

      header.split(',').compact_map do |part|
        media, *parameters = part.split(';')
        type, slash, subtype = media.strip.downcase.partition('/')
        next if slash.empty? || type.empty? || subtype.empty? || (type == "*" && subtype != "*")
        q = 1.0
        valid = true
        parameters.each do |parameter|
          name, _, value = parameter.partition('=')
          next unless name.strip.downcase == "q"
          value = value.strip
          if WEIGHT.matches?(value)
            q = value.to_f
          else
            valid = false
          end
        end
        {type, subtype, q} if valid
      end
    end
  end
end
