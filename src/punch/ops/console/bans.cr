module Punch::Ops::Console
  # ---- Bans ---------------------------------------------------------------

  # An address as a form sends it: IPv4, or IPv6 by its /64, as bans are
  # kept (`HTTP::Probes.address_key`).
  struct BannedAddress
    include Punch::Primitive(String)

    def self.parse(raw : String) : self | Punch::Invalid
      key = HTTP::Probes.address_key(raw)
      key ? new(key) : Punch::Invalid.new("invalid_address")
    end
  end

  # The bans a server's guard knows, with what it answered so far.
  struct BansOverview
    include Punch::Component

    def initialize(@bans : Array(HTTP::Probes::Ban)?, @settings : HTTP::Probes::Settings?, @probes : Int64,
                   @refused : Int64, @now : Time)
    end

    def view(v : Punch::View) : Nil
      v.render Layout.new("Bans") do
        v.h1 "Bans"
        unless (bans = @bans) && (settings = @settings)
          v.p "No server runs in this process, so nothing answers probes here."
          next
        end
        summary(v, settings)
        active = bans.select(&.active?(@now))
        list(v, "Banned now", active, lift: true)
        list(v, "Ended", bans.reject(&.active?(@now)), lift: false)
      end
    end

    private def summary(v : Punch::View, settings : HTTP::Probes::Settings) : Nil
      unless settings.enabled?
        v.p "Probes are off (PUNCH_PROBES=off): requests for scanners' paths reach the router, and nobody is banned."
        return
      end
      v.p "Since this process started: #{@probes} requests for paths only scanners ask for answered 404, #{@refused} requests from banned addresses answered 403."
      if settings.ban_after.zero?
        v.p "Nobody is banned (PUNCH_PROBE_BAN_AFTER=0)."
      else
        steps = settings.bans.join(", ") { |span| RateLimits.span_text(span) }
        v.p "#{settings.ban_after} within #{RateLimits.span_text(settings.window)} ban an address for #{steps}; " \
            "an address's count is forgotten #{HTTP::Probes::Settings::FORGET.total_days.to_i} days after its last ban ended."
      end
    end

    private def list(v : Punch::View, title : String, bans : Array(HTTP::Probes::Ban), *, lift : Bool) : Nil
      v.section do
        v.h2 title
        if bans.empty?
          v.p "None."
          next
        end
        v.table(class: "bans") do
          v.thead { v.tr { ["Address", "Ban", "Since", "Until", "Paths", ""].each { |label| v.th label, scope: "col" } } }
          v.tbody do
            bans.each do |ban|
              v.tr do
                v.th ban.address, scope: "row"
                v.td ban.strikes.to_s
                v.td Console.time(ban.banned_at)
                v.td Console.time(ban.ends_at)
                v.td { ban.paths.each_with_index { |path, index| v.text " " if index > 0; v.code path } }
                v.td do
                  # Addresses were checked when the ban was made.
                  if lift && (address = BannedAddress.parse(ban.address).as?(BannedAddress))
                    v.form(LiftBan.action, values: {address: address}) do |form|
                      form.field :address, as: :hidden
                      form.submit "Lift"
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  # `GET /_punch/bans`: the addresses banned for probing, from `cache.db`,
  # so also those the other process banned.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::AgentReadable]
  @[Punch::Route("GET", "/_punch/bans")]
  @[Punch::Forms(LiftBan)]
  struct BansPage < Punch::Page
    struct Input
      include Punch::Input
    end

    alias Output = BansOverview

    def call(input : Input, db : Punch::Reader, actor : Viewer) : Output
      guard = HTTP::Probes.current? || return BansOverview.new(nil, nil, 0, 0, Time.utc)
      BansOverview.new(guard.list, guard.settings, guard.probes.get, guard.refused.get, Time.utc)
    end
  end

  struct BanLifted
    include JSON::Serializable

    getter address : String

    def initialize(@address)
    end
  end

  # `POST /_punch/bans/lift`: lifts an address's ban in this process and
  # in `cache.db`, and forgets its count; the other process lets it in
  # within 30 seconds. 404 when it is not banned.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::Route("POST", "/_punch/bans/lift")]
  struct LiftBan < Punch::Command
    struct Input
      include Punch::Input

      getter address : BannedAddress
    end

    alias Output = BanLifted | NotFound

    def call(input : Input, db : Punch::Writer, actor : Viewer, grant : Punch::Grant(LiftBan)) : Output
      guard = HTTP::Probes.current? || return NotFound.new
      address = input.address.to_s
      guard.lift(address) ? BanLifted.new(address) : NotFound.new
    end
  end
end
