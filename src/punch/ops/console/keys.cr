module Punch::Ops::Console
  # ---- Keys and credentials -----------------------------------------------

  # One root key of the ring, never its secret: its age, its role, and how
  # many messages it opened since the process started while another key
  # signed.
  record KeyState, id : UInt32, created : Time, pending : Bool, signing : Bool, uses : Int64

  struct KeysOverview
    include Punch::Component

    def initialize(@keys : Array(KeyState)?, @credentials : Credentials::Source?, @now : Time)
    end

    def view(v : Punch::View) : Nil
      v.render Layout.new("Keys and credentials") do
        v.h1 "Keys and credentials"
        keys(v)
        credentials(v)
      end
    end

    private def keys(v : Punch::View) : Nil
      v.section do
        v.h2 "Key ring"
        unless keys = @keys
          v.p "No key ring is loaded: the app's credentials declare no secret_key_base."
          return
        end
        v.p "Old-key uses count the messages a key that does not sign opened since this process started. A key is safe to retire (punch keys:retire) once no process uses it."
        v.table(class: "keys") do
          v.thead { v.tr { ["Key", "Created", "Age", "Role", "Old-key uses"].each { |label| v.th label, scope: "col" } } }
          v.tbody do
            keys.each do |key|
              v.tr do
                v.th key.id.to_s, scope: "row"
                v.td key.created.to_s("%F")
                v.td "#{(@now - key.created).total_days.floor.to_i} days"
                v.td key.signing ? "signs" : (key.pending ? "pending (verifies, promote with punch keys:promote)" : "verifies")
                v.td key.signing ? "–" : key.uses.to_s
              end
            end
          end
        end
      end
    end

    private def credentials(v : Punch::View) : Nil
      v.section do
        v.h2 "Credentials"
        unless source = @credentials
          v.p "The app declares no credentials, or this process did not load them."
          return
        end
        v.p "Environment #{source.environment}, file #{source.file}#{source.key_origin.try { |origin| ", key from #{origin}" }}. Secrets are never shown."
        if source.entries.empty?
          v.p "No credential is declared."
          return
        end
        unset = source.entries.count(&.origin.absent?)
        v.p "#{unset} optional #{unset == 1 ? "credential is" : "credentials are"} not set." if unset > 0
        v.table(class: "credentials") do
          v.thead { v.tr { ["Credential", "From", "Where", "Value"].each { |label| v.th label, scope: "col" } } }
          v.tbody do
            source.entries.each do |entry|
              v.tr do
                v.th(scope: "row") { v.code entry.path }
                v.td entry.origin.absent? ? "not set" : entry.origin.to_s.downcase
                v.td { entry.where.try { |where| v.code where } }
                v.td entry.secret ? "(secret)" : (entry.value || "–")
              end
            end
          end
        end
      end
    end
  end

  # `GET /_punch/keys`: the key ring's keys with their ages and old-key
  # use, and where each credential came from (never a secret's value).
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::AgentReadable]
  @[Punch::Route("GET", "/_punch/keys")]
  struct KeysPage < Punch::Page
    struct Input
      include Punch::Input
    end

    alias Output = KeysOverview

    def call(input : Input, db : Punch::Reader, actor : Viewer) : Output
      keys = KeyRing.current?.try do |ring|
        uses = ring.uses
        ring.keys.map { |key| KeyState.new(key.id, key.created, key.pending?, key.id == ring.signing.id, uses[key.id]? || 0_i64) }
      end
      KeysOverview.new(keys, Credentials.loaded, Time.utc)
    end
  end
end
