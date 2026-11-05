require "openssl"
require "base64"
require "crypto/subtle"

module Punch
  # A password as stored: a versioned hash string in the PHC format,
  # `$pbkdf2-sha256$i=600000$<salt>$<hash>`. The prefix names the algorithm
  # and its parameters, so they can change and old hashes are replaced at
  # the next sign-in.
  struct Auth::PasswordHash
    getter text : String

    # :nodoc:
    def initialize(@text : String)
    end

    def to_s(io : IO) : Nil
      io << "[password hash]"
    end

    def inspect(io : IO) : Nil
      io << "Punch::Auth::PasswordHash([password hash])"
    end

    def to_json(json : JSON::Builder) : Nil
      {% raise "Punch::Auth::PasswordHash cannot be serialized to JSON: hashes stay in punch_passwords (lib/punch/docs/auth.md)." %}
    end
  end

  # 503 with `Retry-After`: the password hasher's queue is full. Answered by
  # the router before any transaction opens.
  record Auth::PasswordsBusy

  # 422 `invalid_credentials`: the email address and password do not
  # belong together. The same answer, after the same work, whether the
  # address is unknown, has no password, or the password is wrong, so a
  # sign-in form does not tell which addresses have accounts.
  @[Punch::Status(422)]
  struct Auth::InvalidCredentials
    include JSON::Serializable

    def initialize
    end
  end

  # The outcome of checking an email address and password before a sign-in
  # Command's transaction (docs/auth.md). A Command takes it in `call`:
  #
  # ```
  # def call(input : Input, db : Punch::Writer, auth : Punch::Auth::Authentication, password : Punch::Auth::PasswordCheck) : SignedIn | Punch::Auth::InvalidCredentials
  #   user_id = password.confirm(db, Users::ID) || return Punch::Auth::InvalidCredentials.new
  #   auth.sign_in(user_id, method: "password")
  #   SignedIn.new
  # end
  # ```
  #
  # The router verifies the password on the hasher before opening the
  # write transaction; `confirm` then checks in the transaction that the
  # address still belongs to the same user and the hash is unchanged, and
  # stores a rehash if one was made.
  class Auth::PasswordCheck
    getter email : Email
    # Whose address it is, matched or not; for `Punch::Auth::SignInFailed`.
    # :nodoc:
    getter owner_id : Int64?

    # :nodoc:
    def initialize(@email : Email, @user_id : Int64?, @hash : String?, @rehash : Auth::PasswordHash?, @owner_id : Int64? = @user_id)
    end

    # Whether the password matched before the transaction.
    def matched? : Bool
      !@user_id.nil?
    end

    # The user whose password this is, confirmed in *db*'s transaction;
    # `nil` when it did not match or changed in between.
    def confirm(db : Writer) : Int64?
      user_id = @user_id || return
      hash = @hash || return
      stored = Auth::Passwords.lookup(db, @email)
      return unless stored && stored[0] == user_id && stored[1] == hash

      if rehash = @rehash
        Auth::Passwords.replace(db, user_id, hash, rehash)
      end
      user_id
    end

    # The same, as the app's typed ID: `password.confirm(db, Users::ID)`.
    def confirm(db : Writer, type : T.class) : T? forall T
      confirm(db).try { |id| type.parse(id).as(T) }
    end
  end

  # The signed-in user's own password, checked before a Command's
  # transaction, for changes that need it: a new password, and
  # re-authenticating a user without a second factor. A Command takes it in
  # `call`, with `getter current_password : Punch::Auth::Password` in its
  # input:
  #
  # ```
  # def call(input : Input, db : Punch::Writer, actor : App::Actor, password : Punch::Auth::OwnPasswordCheck, ...) : Changed | Punch::Auth::InvalidCredentials
  #   return Punch::Auth::InvalidCredentials.new unless password.confirm(db)
  #   ...
  # ```
  #
  # The router finds the user from the request's session, verifies the
  # password on the hasher, then opens the transaction; `confirm` checks
  # there that the stored hash is still the one that matched.
  class Auth::OwnPasswordCheck
    # :nodoc:
    def initialize(@user_id : Int64?, @hash : String?, @rehash : Auth::PasswordHash?)
    end

    # Whether the password matched before the transaction.
    def matched? : Bool
      !@user_id.nil?
    end

    # Whether the password matched and is still the user's, in *db*'s
    # transaction; stores a rehash if one was made.
    def confirm(db : Writer) : Bool
      user_id = @user_id || return false
      hash = @hash || return false
      return false unless Auth::Passwords.stored(db, user_id) == hash

      @rehash.try { |rehash| Auth::Passwords.replace(db, user_id, hash, rehash) }
      true
    end
  end

  # Password hashing and the stored passwords (docs/auth.md).
  #
  # Hashing is PBKDF2-HMAC-SHA256 from the standard library at 600,000
  # iterations, slow on purpose: about 70 ms. It runs in an execution
  # context of its own behind a bounded queue, never on a request's thread
  # and never inside a transaction; when the queue is full, a request is
  # answered 503 at once instead of waiting.
  module Auth::Passwords
    TABLE      = "punch_passwords"
    ALGORITHM  = "pbkdf2-sha256"
    ITERATIONS = 600_000 # OWASP's minimum for PBKDF2-HMAC-SHA256
    SALT_BYTES =      16
    HASH_BYTES =      32
    # Iteration counts accepted when verifying; anything outside is not a
    # hash Punch wrote.
    ITERATION_RANGE = 1..10_000_000

    # The hasher's settings, set once in app code before serving:
    #
    # ```
    # Punch::Auth::Passwords.config = Punch::Auth::Passwords::Config.new(threads: 4)
    # ```
    struct Config
      # PBKDF2 iterations for new hashes. A stored hash with fewer is
      # replaced at the next sign-in.
      getter iterations : Int32
      # Threads of the hashing context. Each hashes about 14 passwords a
      # second.
      getter threads : Int32
      # Hashes that may wait for a thread; one more is answered 503.
      getter queue : Int32
      # The `Retry-After` of that 503.
      getter retry_after : Time::Span

      def initialize(*, @iterations = ITERATIONS, @threads = 2, @queue = 16, @retry_after = 1.second)
        raise ArgumentError.new("iterations must be at least #{ITERATIONS} (OWASP)") unless ITERATIONS <= iterations <= ITERATION_RANGE.end
        check
      end

      # Few iterations, for specs only: `punch/spec` sets it.
      # :nodoc:
      def self.for_specs : self
        config = allocate
        config.initialize_for_specs
        config
      end

      # :nodoc:
      protected def initialize_for_specs : Nil
        @iterations = 1_000
        @threads = 2
        @queue = 64
        @retry_after = 1.second
      end

      private def check : Nil
        raise ArgumentError.new("threads must be 1 to 64") unless 1 <= threads <= 64
        raise ArgumentError.new("queue must be 1 to 10,000") unless 1 <= queue <= 10_000
        raise ArgumentError.new("retry_after must be positive") unless retry_after.positive?
      end
    end

    # Whether a password matches a stored hash.
    enum Verdict
      Valid
      # Correct, but stored with older parameters: hash it again.
      ValidNeedsRehash
      Invalid
    end

    @@config = Config.new
    @@hasher : Hasher?
    @@hasher_lock = Mutex.new

    def self.config : Config
      @@config
    end

    # Replaces the settings; a hasher already running keeps its threads.
    def self.config=(config : Config) : Config
      @@config = config
    end

    # The hashing context, started on first use.
    def self.hasher : Hasher
      @@hasher || @@hasher_lock.synchronize { @@hasher ||= Hasher.new(config.threads, config.queue) }
    end

    # Replaces the hasher, for specs that fill its queue.
    # :nodoc:
    def self.hasher=(hasher : Hasher) : Hasher
      @@hasher_lock.synchronize { @@hasher = hasher }
    end

    # Hashes *password* on the calling fiber. Use `Hasher` in a server;
    # apps hash through `NewPassword` and check through `PasswordCheck`
    # (`Punch/PasswordCheck` reports these calls in app code).
    # :nodoc:
    def self.hash_now(password : String, iterations : Int32 = config.iterations) : Auth::PasswordHash
      salt = Random::Secure.random_bytes(SALT_BYTES)
      Auth::PasswordHash.new("$#{ALGORITHM}$i=#{iterations}$#{b64(salt)}$#{b64(derive(password, salt, iterations))}")
    end

    # Checks *password* against *stored* on the calling fiber, in constant
    # time. A malformed or foreign hash is `Invalid`, after the same work
    # as a real one.
    # :nodoc:
    def self.verify_now(password : String, stored : String) : Verdict
      salt, expected, iterations = parse(stored) || {dummy_salt, nil, config.iterations}
      actual = derive(password, salt, iterations)
      return Verdict::Invalid unless expected && ::Crypto::Subtle.constant_time_compare(actual, expected)

      iterations < config.iterations ? Verdict::ValidNeedsRehash : Verdict::Valid
    end

    # The salt, hash, and iterations of a hash string Punch wrote.
    private def self.parse(stored : String) : {Bytes, Bytes, Int32}?
      parts = stored.split('$')
      return unless parts.size == 5 && parts[0].empty? && parts[1] == ALGORITHM

      iterations = parts[2].lchop?("i=").try(&.to_i?) || return
      return unless ITERATION_RANGE.includes?(iterations)

      salt = unb64(parts[3]) || return
      expected = unb64(parts[4]) || return
      return unless salt.size == SALT_BYTES && expected.size == HASH_BYTES

      {salt, expected, iterations}
    end

    private def self.derive(password : String, salt : Bytes, iterations : Int32) : Bytes
      OpenSSL::PKCS5.pbkdf2_hmac(password, salt, iterations, OpenSSL::Algorithm::SHA256, HASH_BYTES)
    end

    # Whether *stored* was written with the current parameters.
    def self.current?(stored : String) : Bool
      parse(stored).try { |parsed| parsed[2] >= config.iterations } || false
    end

    # The parameters of *stored* (`pbkdf2-sha256 i=600000`), for reports;
    # `unknown` for anything Punch did not write.
    def self.parameters(stored : String) : String
      parsed = parse(stored) || return "unknown"
      "#{ALGORITHM} i=#{parsed[2]}"
    end

    @@dummy_salt : Bytes?

    private def self.dummy_salt : Bytes
      @@dummy_salt ||= Random::Secure.random_bytes(SALT_BYTES)
    end

    private def self.b64(bytes : Bytes) : String
      Base64.strict_encode(bytes).rstrip('=')
    end

    private def self.unb64(text : String) : Bytes?
      return unless text.each_char.all? { |char| char.ascii_alphanumeric? || char == '+' || char == '/' }

      Base64.decode(text + "=" * ((4 - text.size % 4) % 4))
    rescue Base64::Error
      nil
    end

    # Runs password work on threads of its own. The queue is bounded: when
    # it is full, `run` returns `false` at once, and the caller answers 503
    # rather than piling up work behind the limit that rate limits are meant
    # to keep.
    class Hasher
      record Job, work : Proc(Nil), done : Channel(Nil)

      getter threads : Int32
      getter capacity : Int32
      # Jobs that can run at once: two fibers per thread. More fibers
      # than threads keeps every thread busy under load (one fiber per
      # thread sometimes leaves threads parked).
      getter workers : Int32

      def initialize(@threads : Int32, @capacity : Int32)
        @workers = @threads * 2
        @queued = Atomic(Int32).new(0)
        @queue = Channel(Job).new(@capacity)
        @context = Fiber::ExecutionContext::Parallel.new("punch-passwords", @threads)
        @workers.times do
          @context.spawn(name: "punch-password") do
            while job = @queue.receive?
              @queued.sub(1)
              job.work.call
              job.done.send(nil)
            end
          end
        end
      end

      # Jobs waiting for a worker, roughly; for statistics and specs.
      def queued : Int32
        @queued.get
      end

      # Runs *work* on a hashing thread and waits for it; `false` without
      # running it when the queue is full.
      def run(&work : -> Nil) : Bool
        done = Channel(Nil).new(1)
        select
        when @queue.send(Job.new(work, done))
          @queued.add(1)
          done.receive
          true
        else
          false
        end
      end

      def hash(password : String) : Auth::PasswordHash | Auth::PasswordsBusy
        result = nil.as(Auth::PasswordHash?)
        ran = run { result = Auth::Passwords.hash_now(password) }
        hashed = result
        ran && hashed ? hashed : Auth::PasswordsBusy.new
      end

      def verify(password : String, stored : String) : Verdict | Auth::PasswordsBusy
        result = Verdict::Invalid
        run { result = Auth::Passwords.verify_now(password, stored) } || return Auth::PasswordsBusy.new
        result
      end
    end

    # Hashes *password* on the hasher before a transaction opens, so its
    # `hashed` is ready inside. The router calls it for every `Auth::NewPassword`
    # field of a Command's input.
    def self.prepare(password : Auth::NewPassword, span : Trace::Span) : Auth::PasswordsBusy?
      return if password.hashed?

      child = span.child("password.hash")
      begin
        case hashed = hasher.hash(password.unwrap)
        in Auth::PasswordHash
          password.hashed = hashed
          nil
        in Auth::PasswordsBusy
          child.set("punch.password", "busy")
          hashed
        end
      ensure
        child.finish
      end
    end

    # Checks *password* for the user whose email identity is *email*,
    # before a transaction: looks the hash up in a read transaction,
    # verifies it on the hasher (against a stand-in hash when there is
    # none, so unknown addresses take as long), and hashes again when the
    # stored parameters are old. The router calls it for a Command that
    # takes `Punch::Auth::PasswordCheck`.
    def self.check(database : Database, email : Email, password : Auth::Password, span : Trace::Span = Trace::Span::NOOP) : Auth::PasswordCheck | Auth::PasswordsBusy
      stored = database.read { |db| lookup(db, email) }
      child = span.child("password.verify")
      begin
        verdict = hasher.verify(password.unwrap, stored.try(&.[1]) || "")
        if verdict.is_a?(Auth::PasswordsBusy)
          child.set("punch.password", "busy")
          return verdict
        end
        rehash = nil.as(Auth::PasswordHash?)
        if verdict.valid_needs_rehash?
          case hashed = hasher.hash(password.unwrap)
          in Auth::PasswordHash  then rehash = hashed
          in Auth::PasswordsBusy then nil # verified all the same; the rehash waits for the next sign-in
          end
        end
        matched = stored && !verdict.invalid?
        outcome = matched ? (rehash ? "rehashed" : "valid") : "invalid"
        child.set("punch.password", outcome)
        span.set("punch.password", outcome) if span.recording?
        matched && stored ? Auth::PasswordCheck.new(email, stored[0], stored[1], rehash) : Auth::PasswordCheck.new(email, nil, nil, nil, stored.try(&.[0]))
      ensure
        child.finish
      end
    end

    # Checks *password* against the stored hash of *user_id* (the
    # request's signed-in user, `nil` without one) before a transaction, as
    # `check` does for an address. The router calls it for a Command that
    # takes `Punch::Auth::OwnPasswordCheck`.
    def self.check_own(database : Database, user_id : Int64?, password : Auth::Password, span : Trace::Span = Trace::Span::NOOP) : Auth::OwnPasswordCheck | Auth::PasswordsBusy
      stored = user_id ? database.read { |db| stored(db, user_id) } : nil
      child = span.child("password.verify")
      begin
        verdict = hasher.verify(password.unwrap, stored || "")
        if verdict.is_a?(Auth::PasswordsBusy)
          child.set("punch.password", "busy")
          return verdict
        end
        rehash = nil.as(Auth::PasswordHash?)
        if verdict.valid_needs_rehash?
          hashed = hasher.hash(password.unwrap)
          rehash = hashed if hashed.is_a?(Auth::PasswordHash)
        end
        matched = stored && !verdict.invalid?
        outcome = matched ? (rehash ? "rehashed" : "valid") : "invalid"
        child.set("punch.password", outcome)
        span.set("punch.password", outcome) if span.recording?
        matched ? Auth::OwnPasswordCheck.new(user_id, stored, rehash) : Auth::OwnPasswordCheck.new(nil, nil, nil)
      ensure
        child.finish
      end
    end

    # The stored hash of *user_id*, `nil` without a password.
    # :nodoc:
    def self.stored(db : Reader | Writer, user_id : Int64) : String?
      db.query_one?("SELECT hash FROM punch_passwords WHERE user_id = ?", user_id, name: "Punch::Auth::Passwords.stored", &.read(String))
    end

    # The 503 for a full hasher: a page for clients that prefer HTML,
    # Problem Details otherwise, with `Retry-After`.
    def self.busy(context : HTTP::Context) : HTTP::Response
      context.span.set("punch.outcome", "passwords_busy")
      response = if HTTP::Accept.preferred(context.request.headers["Accept"]?, Routing::Router::OFFERS) == "text/html"
                   Pages.problem(:service_unavailable, "passwords_busy", context)
                 else
                   HTTP::Response.problem(:service_unavailable, context, "passwords_busy")
                 end
      response.headers["Retry-After"] = Math.max(config.retry_after.total_seconds.ceil.to_i, 1).to_s
      HTTP::Accept.vary(response)
    end

    # The user ID and stored hash behind the email identity *email*; the
    # hash is `nil` when the user has no password.
    # :nodoc:
    def self.lookup(db : Reader | Writer, email : Email) : {Int64, String?}?
      db.query_one?(<<-SQL, email.value, name: "Punch::Auth::Passwords.lookup") { |row| {row.read(Int64), row.read(String?)} }
        SELECT i.user_id, p.hash FROM punch_email_identities i
        LEFT JOIN punch_passwords p ON p.user_id = i.user_id
        WHERE i.email = ?
        SQL
    end

    # Sets the password of *user_id*, replacing any it had. Ending the
    # user's other sessions is the caller's step, with
    # `Auth::Sessions.revoke_all(db, user_id, except:)`.
    def self.set(db : Writer, user_id : TypedID | Int64, hash : Auth::PasswordHash, *, now : Time = Time.utc) : Nil
      raw = user_id.is_a?(TypedID) ? user_id.value : user_id
      time = Stored.dump(now)
      db.exec(<<-SQL, raw, hash.text, time, time, name: "Punch::Auth::Passwords.set")
        INSERT INTO punch_passwords (user_id, hash, created_at, updated_at) VALUES (?, ?, ?, ?)
        ON CONFLICT (user_id) DO UPDATE SET hash = excluded.hash, updated_at = excluded.updated_at
        SQL
    end

    # Replaces *old* with *rehash* after a sign-in, unless the password
    # changed meanwhile.
    # :nodoc:
    def self.replace(db : Writer, user_id : Int64, old : String, rehash : Auth::PasswordHash, *, now : Time = Time.utc) : Nil
      db.exec("UPDATE punch_passwords SET hash = ?, updated_at = ? WHERE user_id = ? AND hash = ?",
        rehash.text, Stored.dump(now), user_id, old, name: "Punch::Auth::Passwords.rehash")
    end

    # Whether *user_id* has a password. A user without one is normal: they
    # sign in another way.
    def self.set?(db : Reader | Writer, user_id : TypedID | Int64) : Bool
      raw = user_id.is_a?(TypedID) ? user_id.value : user_id
      !db.query_one?("SELECT 1 FROM punch_passwords WHERE user_id = ?", raw, name: "Punch::Auth::Passwords.set?") { |row| row.read(Int64) }.nil?
    end

    # How many stored hashes use which parameters, for `punch passwords`.
    def self.census(db : Reader | Writer) : Hash(String, Int64)
      counts = Hash(String, Int64).new(0_i64)
      db.query_each("SELECT hash FROM punch_passwords", name: "Punch::Auth::Passwords.census") do |row|
        counts[parameters(row.read(String))] += 1
      end
      counts
    end
  end
end
