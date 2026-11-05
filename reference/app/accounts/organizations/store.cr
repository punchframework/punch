# Loads and saves organizations and who belongs to them: the
# organization a session or token works in, founding one, and the roles of
# its members (`Accounts::Roles`). Call it inside one `read` or `write`
# (lib/punch/docs/models.md).
module Accounts::Organizations::Store
  extend self

  # The organization *principal* works in: the one its session or token
  # chose, while the user still holds a role there, else the one they
  # were given a role on first (their own, for a user who signed up). The
  # actor loads it on every request, so it reads the user's roles through
  # `Punch::Roles.held`, which the policy then asks again without a query.
  def current(db : Punch::Reader | Punch::Writer, principal : Punch::Auth::Principal) : Record?
    held = held_ids(db, principal.user_id)
    chosen = case via = principal.via
             in Punch::Auth::Session  then Queries.choice_by_session(db, session_id: via.id)
             in Punch::Auth::APIToken then Queries.choice_by_token(db, api_token_id: via.id)
             end
    id = chosen.try(&.organization_id).try { |choice| choice if held.includes?(choice.value) }
    id ||= held.first?.try { |first| ID.parse(first).as(ID) }
    id.try { |found| Table.find(db, found) }
  end

  # The organization *user_id* was given a live role on first.
  def first(db : Punch::Reader | Punch::Writer, user_id : Users::ID) : Record?
    held_ids(db, user_id.value).first?.try { |id| Table.find(db, ID.parse(id).as(ID)) }
  end

  # The organizations *user_id* holds a live role on, oldest assignment
  # first.
  private def held_ids(db : Punch::Reader | Punch::Writer, user_id : Int64) : Array(Int64)
    type = Punch::Roles.resource_type(ID)
    Punch::Roles.held(db, user_id).compact_map { |held| held.resource_id if held.resource_type == type }
  end

  # Makes *organization_id* the one *principal*'s session or token works in.
  def choose(db : Punch::Writer, principal : Punch::Auth::Principal, organization_id : ID) : Nil
    case via = principal.via
    in Punch::Auth::Session  then Queries.choose_for_session(db, session_id: via.id, organization_id: organization_id)
    in Punch::Auth::APIToken then Queries.choose_for_token(db, api_token_id: via.id, organization_id: organization_id)
    end
  end

  # A new organization named *name*, founded *at*, whose administrator is
  # *founder*, and that assignment, for the caller to publish. It speaks
  # the founder's language.
  def found(db : Punch::Writer, name : Punch::NonEmptyString, founder : Users::Record, at : Time) : {Record, Punch::Roles::Assignment}
    organization = Table.insert(db, name: name, locale: founder.locale, created_at: at)
    assigned, _ = give(db, founder.id, :administrator, on: organization.id, assigned_by: founder.id)
    {organization, assigned}
  end

  # The members of *organization_id* with live roles, by name. An
  # organization has a few, so each is one lookup.
  def members(db : Punch::Reader | Punch::Writer, organization_id : ID) : Array(Members::Membership)
    Punch::Roles.assignments(db, on: organization_id).compact_map do |assignment|
      next if assignment.expired?
      role = Roles::Name.stored?(assignment.role) || next
      user = Users::Table.find(db, Users::ID.parse(assignment.user_id).as(Users::ID)) || next
      Members::Membership.new(organization_id, user, role, assignment.expires_at)
    end.sort_by! { |member| {member.name.value, member.user_id.value} }
  end

  # Gives *user_id* the role *name* on *organization*, and takes the other
  # ones they held there. Returns the assignment and those that ended.
  def give(db : Punch::Writer, user_id : Users::ID, name : Roles::Name, *, on organization : ID,
           expires_at : Time? = nil, assigned_by : Users::ID? = nil) : {Punch::Roles::Assignment, Array(Punch::Roles::Assignment)}
    ended = Roles::Name.values.reject(name).compact_map { |other| take(db, user_id, other, on: organization) }
    assigned = case name
               in .member?        then Punch::Roles.assign(db, user_id, Roles::Member, on: organization, expires_at: expires_at, assigned_by: assigned_by)
               in .editor?        then Punch::Roles.assign(db, user_id, Roles::Editor, on: organization, expires_at: expires_at, assigned_by: assigned_by)
               in .administrator? then Punch::Roles.assign(db, user_id, Roles::Administrator, on: organization, expires_at: expires_at, assigned_by: assigned_by)
               end
    {assigned, ended}
  end

  # Takes the role *name* on *organization* from *user_id*; the assignment
  # that ended, or `nil`.
  def take(db : Punch::Writer, user_id : Users::ID, name : Roles::Name, *, on organization : ID) : Punch::Roles::Assignment?
    case name
    in .member?        then Punch::Roles.revoke(db, user_id, Roles::Member, on: organization)
    in .editor?        then Punch::Roles.revoke(db, user_id, Roles::Editor, on: organization)
    in .administrator? then Punch::Roles.revoke(db, user_id, Roles::Administrator, on: organization)
    end
  end

  # The role *user_id* holds on *organization* now, if any.
  def held(db : Punch::Reader | Punch::Writer, user_id : Users::ID, *, on organization : ID) : Roles::Name?
    live = Punch::Roles.assignments(db, on: organization).find { |assignment| assignment.user_id == user_id.value && !assignment.expired? }
    live.try { |assignment| Roles::Name.stored?(assignment.role) }
  end

  # Whether taking the administrator role from *user_id* would leave
  # *organization* without one.
  def last_administrator?(db : Punch::Reader | Punch::Writer, user_id : Users::ID, *, on organization : ID) : Bool
    held(db, user_id, on: organization).try(&.administrator?) == true &&
      Punch::Roles.holders(db, Roles::Administrator, on: organization) <= 1
  end
end
