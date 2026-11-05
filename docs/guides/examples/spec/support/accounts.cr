module AccountsSpec
  def self.user(name = "Ingrid Iversen") : Accounts::Users::Record
    Punch::Spec.db.write { |db| user(db, name) }
  end

  # A new user, as after sign-up.
  def self.user(db : Punch::Writer, name = "Ingrid Iversen") : Accounts::Users::Record
    Accounts::Users::Table.insert(db, name: ExamplesSpec.parse(Punch::NonEmptyString, name), created_at: Time.utc)
  end

  # A client signed in as a new user who holds `Operator`: the ops
  # console is theirs.
  def self.operator : Punch::Spec::Client
    user = self.user
    Punch::Spec.db.write { |db| Punch::Roles.assign(db, user.id, Accounts::Roles::Operator) }
    Punch::Spec.client.sign_in(user.id)
  end

  # A client signed in as a new user.
  def self.client : Punch::Spec::Client
    Punch::Spec.client.sign_in(user.id)
  end

  # Signs up through the form as a browser does, follows the mailed link,
  # and signs in: a password signs in only once an address is verified.
  def self.sign_up(client : Punch::Spec::Client, email : String, password : String, name = "Ingrid") : Punch::Spec::Client
    client.submit(Accounts::SignUp::Create.action, form: {"name" => name, "email" => email, "password" => password})
      .should redirect_to(Accounts::SignUp::CreatePage.href(sent: true))
    verify(email)
    client.submit(Accounts::Sessions::Create.action, form: {"email" => email, "password" => password})
      .should redirect_to(Home::IndexPage.href)
    client
  end

  # Follows the last verification link mailed to *email*, from another
  # browser, as its owner would.
  def self.verify(email : String) : Nil
    Punch::Spec.perform_jobs
    link = Accounts::Emails::VerifyPage.href.url
    path = Punch::Spec.mails(to: email).compact_map(&.paths.find(&.starts_with?(link))).last? || fail "no verification link mailed to #{email}"
    token = URI.parse(path).query_params["token"]
    Punch::Spec.client.submit(Accounts::Emails::Verify.action, form: {"token" => token}).should redirect_to(Accounts::Sessions::CreatePage.href)
  end
end
