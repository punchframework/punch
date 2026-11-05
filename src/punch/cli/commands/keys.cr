module Punch::CLI::Commands
  # What the `keys:` commands share: the key ring in `secret_key_base` of an
  # environment's credentials file, read and written like `creds:set` does.
  module Keys
    FIELD    = "secret_key_base"
    VARIABLE = "SECRET_KEY_BASE"

    record Loaded, environment : String, tree : Hash(String, Punch::Credentials::Tree),
      master : Punch::Credentials::MasterKey, ring : Punch::KeyRing?

    def self.load(args : Array(String), command : String) : Loaded | Failure
      environment = Creds.environment(args, command)
      return environment if environment.is_a?(Failure)

      read = Creds.read_tree(environment)
      return read if read.is_a?(Failure)

      tree, master = read
      file = Punch::Credentials.file(environment)
      ring = case raw = tree[FIELD]?
             in Nil then nil
             in String
               case parsed = Punch::KeyRing.parse(raw)
               in Punch::KeyRing then parsed
               in Punch::Invalid
                 return Failure.new("invalid_key_ring", "#{FIELD} in #{file} is not a key ring (#{parsed.params.map { |key, value| "#{key} #{value}" }.join(", ")}).")
               end
             in Hash(String, Punch::Credentials::Tree), Array(Punch::Credentials::Tree)
               return Failure.new("invalid_key_ring", "#{FIELD} in #{file} must be text, one key per line.")
             end
      Loaded.new(environment, tree, master, ring)
    end

    # Writes *ring* into the file and reports it.
    def self.save(loaded : Loaded, ring : Punch::KeyRing, notes : Array(String)) : Report
      tree = loaded.tree
      tree[FIELD] = ring.to_text + "\n"
      Creds.write(loaded.environment, Punch::Credentials::YAMLTree.dump(tree), loaded.master)
      notes << "#{VARIABLE} is set here and overrides the file; update it too." if ENV[VARIABLE]?.presence
      Listing.new(loaded.environment, ring, notes)
    end

    def self.next_id(ring : Punch::KeyRing) : UInt32
      ring.keys.max_of(&.id) + 1
    end

    def self.state(ring : Punch::KeyRing, key : Punch::KeyRing::Key) : String
      key.pending? ? "pending" : key.id == ring.signing.id ? "signing" : "accepted"
    end

    # The keys of a ring, never their secrets.
    struct Listing
      include Report

      def initialize(@environment : String, @ring : Punch::KeyRing?, @notes : Array(String) = [] of String, @today : Time = Time.utc)
      end

      def to_text(io : IO) : Nil
        if ring = @ring
          io.puts "Key ring for #{@environment} (#{Punch::Credentials.file(@environment)}):"
          ring.keys.each do |key|
            io.puts "  #{key.id.to_s.rjust(4)}  #{Keys.state(ring, key).ljust(8)}  created #{key.created.to_s("%F")}, #{age(key)} days ago"
          end
        else
          io.puts "No key ring in #{Punch::Credentials.file(@environment)}. Run 'punch keys:rotate --env #{@environment}' to create one."
        end
        @notes.each { |note| io.puts note }
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "environment", @environment
          json.field "keys" do
            json.array do
              if ring = @ring
                ring.keys.each do |key|
                  json.object do
                    json.field "id", key.id
                    json.field "state", Keys.state(ring, key)
                    json.field "created", key.created.to_s("%F")
                    json.field "age_days", age(key)
                  end
                end
              end
            end
          end
          json.field "notes", @notes
        end
      end

      private def age(key : Punch::KeyRing::Key) : Int32
        (@today - key.created).total_days.floor.to_i
      end
    end
  end

  # Lists the key ring of an environment: IDs, states, ages; no secrets.
  class KeysList < Command
    command "keys", "List the key ring (secret_key_base) of an environment: ids, states, ages; --env NAME"

    def run(args : Array(String)) : Report | Failure
      loaded = Keys.load(args, "keys")
      return loaded if loaded.is_a?(Failure)
      if failure = no_arguments(args)
        return failure
      end

      Keys::Listing.new(loaded.environment, loaded.ring)
    end
  end

  # Starts a rotation: a new key, pending, which every process accepts once
  # deployed; `keys:promote` makes it sign. Creates the first key when there
  # is none. `--revoke`, after a compromise, replaces every key at once.
  class KeysRotate < Command
    command "keys:rotate", "Add a new pending key to secret_key_base (first step of a rotation); --revoke replaces every key at once; --env NAME"

    def run(args : Array(String)) : Report | Failure
      revoke = args.delete("--revoke")
      loaded = Keys.load(args, "keys:rotate")
      return loaded if loaded.is_a?(Failure)
      if failure = no_arguments(args)
        return failure
      end

      ring = loaded.ring
      unless ring
        return Keys.save(loaded, Punch::KeyRing.new([Punch::KeyRing::Key.generate(1)]),
          ["Created key 1. Nothing was signed before, so no handover is needed; rebuild and deploy."])
      end
      if revoke
        fresh = Punch::KeyRing::Key.generate(Keys.next_id(ring))
        return Keys.save(loaded, Punch::KeyRing.new([fresh]), [
          "Revoked keys #{ring.keys.join(", ", &.id)}: everything they signed or encrypted no longer opens. Rebuild and deploy at once.",
        ])
      end
      if pending = ring.keys.find(&.pending?)
        return Failure.new("rotation_in_progress", "Key #{pending.id} is pending already. Deploy it everywhere, then run 'punch keys:promote --env #{loaded.environment}'.")
      end

      fresh = Punch::KeyRing::Key.generate(Keys.next_id(ring), pending: true)
      Keys.save(loaded, Punch::KeyRing.new([fresh] + ring.keys), [
        "Added key #{fresh.id}, pending. Rebuild and deploy to every process, then run 'punch keys:promote --env #{loaded.environment}' and deploy again.",
      ])
    end
  end

  # The second step of a rotation: the pending key signs and encrypts; the
  # previous one is still accepted.
  class KeysPromote < Command
    command "keys:promote", "Make the pending key of secret_key_base the signing key (second step of a rotation); --env NAME"

    def run(args : Array(String)) : Report | Failure
      loaded = Keys.load(args, "keys:promote")
      return loaded if loaded.is_a?(Failure)
      if failure = no_arguments(args)
        return failure
      end

      ring = loaded.ring
      pending = ring.try &.keys.find(&.pending?)
      unless ring && pending
        return Failure.new("nothing_pending", "No key is pending in #{Punch::Credentials.file(loaded.environment)}. Start a rotation with 'punch keys:rotate --env #{loaded.environment}'.")
      end

      previous = ring.signing
      promoted = Punch::KeyRing.new([pending.with_pending(false)] + ring.keys.reject(&.id.==(pending.id)))
      Keys.save(loaded, promoted, [
        "Key #{pending.id} signs now; key #{previous.id} is still accepted. Rebuild and deploy. Once nothing signed with key #{previous.id} is needed, run 'punch keys:retire #{previous.id} --env #{loaded.environment}'.",
      ])
    end
  end

  # The last step: removes a key that no longer signs. What it signed or
  # encrypted stops opening.
  class KeysRetire < Command
    command "keys:retire", "Remove a key that no longer signs from secret_key_base (last step of a rotation); --env NAME"

    def run(args : Array(String)) : Report | Failure
      loaded = Keys.load(args, "keys:retire")
      return loaded if loaded.is_a?(Failure)

      text = args.shift?
      return Failure.usage("missing_argument", "'punch keys:retire' needs the ID of the key to retire (see 'punch keys').") unless text
      if failure = no_arguments(args)
        return failure
      end

      id = text.to_u32? || return Failure.usage("invalid_argument", "'#{text}' is not a key ID.")
      ring = loaded.ring
      key = ring.try(&.find(id))
      return Failure.new("unknown_key", "There is no key #{id} in #{Punch::Credentials.file(loaded.environment)}.") unless ring && key
      if key.id == ring.signing.id
        return Failure.new("signing_key", "Key #{id} signs; rotate and promote another key before retiring it.")
      end

      retired = Punch::KeyRing.new(ring.keys.reject(&.id.==(id)))
      note = key.pending? ? "Removed pending key #{id}; the rotation is abandoned." : "Retired key #{id}: what it signed or encrypted no longer opens."
      Keys.save(loaded, retired, ["#{note} Rebuild and deploy."])
    end
  end

  # Writes the key of public IDs, `public_id_key`, outside the key ring.
  # It is never rotated: a new key gives every record a new public ID, so
  # replacing it takes `--replace`, for a key that leaked or for an app
  # whose public IDs never left it.
  class KeysPublicID < Command
    command "keys:public-id", "Create public_id_key, the key of public IDs, outside the key ring; --replace changes every public ID; --env NAME"

    FIELD    = "public_id_key"
    VARIABLE = "PUBLIC_ID_KEY"

    def run(args : Array(String)) : Report | Failure
      replace = args.delete("--replace")
      environment = Creds.environment(args, "keys:public-id")
      return environment if environment.is_a?(Failure)
      if failure = no_arguments(args)
        return failure
      end

      read = Creds.read_tree(environment)
      return read if read.is_a?(Failure)

      tree, master = read
      file = Punch::Credentials.file(environment)
      if tree.has_key?(FIELD) && !replace
        return Failure.new("key_exists", "#{file} has a #{FIELD} already. Replacing it changes every public ID and breaks every link that holds one; to do so anyway, run 'punch keys:public-id --replace --env #{environment}'.")
      end

      notes = [tree.has_key?(FIELD) ? "Replaced #{FIELD}: every public ID changes, and the old ones no longer resolve. Rebuild and deploy." : "Created #{FIELD}. Keep it for as long as the app's public IDs are in use; rebuild and deploy."]
      tree[FIELD] = Punch::PublicIDKey.generate.to_text
      Creds.write(environment, Punch::Credentials::YAMLTree.dump(tree), master)
      notes << "#{VARIABLE} is set here and overrides the file; update it too." if ENV[VARIABLE]?.presence
      Creds::Written.new(environment, [{file, "written"}], notes)
    end
  end
end
