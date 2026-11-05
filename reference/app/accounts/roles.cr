module Accounts::Roles
  # Runs the app: the ops console at /_punch, in every organization and
  # outside them. Given on the box with `bin/invoicing roles:assign
  # Accounts::Roles::Operator --email ADDRESS`.
  struct Operator
    include Punch::Role

    permits Punch::Ops::Console::Operations
  end

  # Sees an organization's customers and invoices, and who belongs to it.
  struct Member
    include Punch::Role

    scope Organizations::ID
    permits Organizations::Switch, Organizations::Members::Index, Organizations::Members::IndexPage,
      Billing::Customers::Index, Billing::Customers::IndexPage, Billing::Customers::Search,
      Billing::Customers::Show, Billing::Customers::UpdatePage, Billing::Customers::Statement,
      Billing::Invoices::Index, Billing::Invoices::IndexPage, Billing::Invoices::Show, Billing::Invoices::ShowPage,
      Billing::Profiles::Show, Billing::Profiles::UpdatePage
  end

  # A member who also adds and changes customers, writes invoices, sends
  # them, and shares their links.
  struct Editor
    include Punch::Role

    scope Organizations::ID
    permits Member,
      Billing::Customers::Create, Billing::Customers::CreatePage, Billing::Customers::Update,
      Billing::Invoices::Create, Billing::Invoices::CreatePage, Billing::Invoices::Update,
      Billing::Invoices::Destroy, Billing::Invoices::Send, Billing::Invoices::Link
  end

  # An editor who also decides who belongs to the organization, in
  # which role, and how it appears on its invoices.
  struct Administrator
    include Punch::Role

    scope Organizations::ID
    permits Editor, Organizations::Members::Create, Organizations::Members::Destroy, Billing::Profiles::Update
  end

  # The role a member holds, as requests and forms name it. Each member
  # holds one: they include each other.
  enum Name
    Member
    Editor
    Administrator

    # The role's name in `punch_role_assignments`.
    def stored : String
      case self
      in .member?        then Punch::Roles.role_name(Roles::Member)
      in .editor?        then Punch::Roles.role_name(Roles::Editor)
      in .administrator? then Punch::Roles.role_name(Roles::Administrator)
      end
    end

    def self.stored?(role : String) : self?
      values.find { |name| name.stored == role }
    end
  end
end
