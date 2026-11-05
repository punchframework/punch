module Accounts::Organizations::Members
  @[Punch::Status(200)]
  struct ListView
    include Punch::Component

    def initialize(@organization : Record, @list : List, @actor : Invoicing::Actor)
    end

    def view(v : Punch::View) : Nil
      t = v.t.accounts.members
      title = t.title(name: @organization.name.to_s)
      v.render Invoicing::Layout.new(title, @actor) do
        v.h1 title
        v.table(class: "members") do
          v.thead { v.tr { [t.name, t.role, t.expires, ""].each { |label| v.th label, scope: "col" } } }
          v.tbody { @list.members.each { |member| row(v, member) } }
        end
        # Administrators only: the form asks the policy.
        v.form(Create.action(organization_id: @organization.id), class: "add-member") do |form|
          v.h2 t.add_heading
          form.field :email, hint: t.email_hint
          form.field :role, options: Roles::Name.values.map { |name| {name, Members.role(v, name)} }
          form.submit t.add
        end
      end
    end

    # A remove button for administrators, a leave button on the viewer's
    # own row (`Removal`).
    private def row(v : Punch::View, member : Membership) : Nil
      t = v.t.accounts.members
      v.tr do
        v.td member.name.to_s
        v.td Members.role(v, member.role)
        v.td { member.expires_at.try { |time| v.time v.locale.date(time), datetime: time } }
        v.td do
          v.form(Destroy.action(organization_id: @organization.id, user_id: member.user_id)) do |form|
            form.submit member.user_id == @actor.user.id ? t.leave : t.remove
          end
        end
      end
    end
  end

  # A role's name for people.
  def self.role(v : Punch::View, name : Roles::Name) : String
    roles = v.t.accounts.roles

    case name
    in .member?        then roles.member
    in .editor?        then roles.editor
    in .administrator? then roles.administrator
    end
  end

  # `GET /accounts/organizations/:organization_id/members`: who belongs to
  # the organization in which role. Administrators also see the forms to
  # add, change, and remove members; everyone a button to leave.
  @[Punch::Authorize(ByRole)]
  @[Punch::Forms(Create, Destroy)]
  struct IndexPage < Punch::Page
    alias Input = Index::Input

    alias Output = ListView | NotFound

    def call(input : Input, db : Punch::Reader, actor : Invoicing::Actor) : Output
      organization = Table.find(db, input.organization_id) || return NotFound.new
      ListView.new(organization, Index.new.call(input, db, actor), actor)
    end

    def self.redirect(result : Membership) : Punch::Href
      IndexPage.href(organization_id: result.organization_id)
    end

    # Leaving ends on the list of organizations; removing someone else
    # stays here.
    def self.redirect(result : Removed) : Punch::Href
      result.left? ? Organizations::IndexPage.href : IndexPage.href(organization_id: result.organization_id)
    end
  end
end
