module Punch::Spec
  # An API token for *user_id* in `Punch::Spec.db`, for
  # `headers: HTTP::Headers{"Authorization" => "Bearer #{token}"}`.
  def self.api_token(user_id : TypedID | Int64, *, name : String = "spec", valid : Time::Span = 1.day, now : Time = Time.utc) : String
    raw = user_id.is_a?(TypedID) ? user_id.value : user_id

    case created = db.write { |writer| Auth::APITokens.create(writer, raw, name, now + valid, now: now) }
    in Invalid                               then raise ArgumentError.new("API token not created: #{created.code}")
    in Tuple(Auth::APIToken, Secret(String)) then created[1].unwrap
    end
  end

  # Headers that authenticate with *token*.
  def self.bearer(token : String) : ::HTTP::Headers
    ::HTTP::Headers{"Authorization" => "Bearer #{token}"}
  end

  # The `Idempotency-Key` header with *key*.
  def self.idempotency_key(key : String = Random::Secure.urlsafe_base64(18)) : ::HTTP::Headers
    ::HTTP::Headers{IdempotencyKeys::HEADER => key}
  end
end

module Punch::Spec
  # Gives *user_id* the email identity *email* and the password
  # *password* in `Punch::Spec.db`, so a spec can sign in through the
  # app's own sign-in Command:
  #
  # ```
  # Punch::Spec.password_account(user.id, "ada@example.org", "correct horse battery")
  # client.submit(Accounts::SignIn.action, {email: "ada@example.org", password: "correct horse battery"})
  # ```
  #
  # Specs hash with 1,000 iterations instead of 600,000, so this costs
  # microseconds; the format and the checks are the same.
  def self.password_account(user_id : TypedID | Int64, email : String, password : String, *, verified : Bool = false) : Nil
    address = Email.parse(email)
    raise ArgumentError.new("not an email address: #{email.inspect}") if address.is_a?(Invalid)
    plain = Auth::NewPassword.parse(password)
    raise ArgumentError.new("not a valid new password: #{plain.code}") if plain.is_a?(Invalid)
    hashed = plain.hashed
    db.write do |writer|
      identity = Auth::EmailIdentities.add(writer, user_id, address, verified_at: verified ? Time.utc : nil)
      raise ArgumentError.new("#{email} is taken") if identity.is_a?(Auth::EmailIdentities::EmailTaken)
      Auth::Passwords.set(writer, user_id, hashed)
    end
  end
end

# Hashing at 600,000 iterations costs about 70 ms; specs use 1,000.
Punch::Auth::Passwords.config = Punch::Auth::Passwords::Config.for_specs

module Punch::Spec
  # The grant of *operation* for *actor*, from its policy, for specs that
  # call a Command directly (docs/authorization.md). Raises when the
  # policy refuses, so the example fails where it asked.
  def self.grant(operation : O.class, actor, db : Reader | Writer, **params) : Grant(O) forall O
    case grant = Grant(O).check(actor, db, **params)
    in Grant(O)        then grant
    in Policy::Refused then raise "#{O}'s policy refused: #{grant.code}"
    end
  end
end

module Punch::Spec
  # Gives *user_id* a confirmed authenticator app in `Punch::Spec.db`, so
  # signing in takes a second step. Returns its secret, for
  # `Punch::Spec.totp_code(secret)`. Needs a key ring
  # (`Punch::Spec.credentials`), which encrypts the secret.
  def self.second_factor(user_id : TypedID | Int64, *, now : Time = Time.utc) : Bytes
    db.write do |writer|
      setup = Auth::SecondFactors.start(writer, user_id, now: now)
      raise ArgumentError.new("#{user_id} has a second factor already") if setup.is_a?(Auth::SecondFactorEnabled)
      secret = setup.secret.unwrap
      code = Auth::OneTimeCode.parse(Auth::TOTP.code(secret, now)).as(Auth::OneTimeCode)
      Auth::SecondFactors.confirm(writer, user_id, code, now: now) || raise "the setup did not confirm"
      # The code that confirmed works once; the spec may use it again.
      writer.exec("UPDATE punch_totp_authenticators SET last_step = 0 WHERE user_id = ?", user_id.is_a?(TypedID) ? user_id.value : user_id)
      secret
    end
  end

  # The authenticator app's code for *secret* at *time*.
  def self.totp_code(secret : Bytes, time : Time = Time.utc) : String
    Auth::TOTP.code(secret, time)
  end
end
