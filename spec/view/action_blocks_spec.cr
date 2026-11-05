require "../spec_helper"
require "../support/auth_schema"

module ActionBlocksSpec
  SQL = AuthSchema::SQL + Punch::IdempotencyKeys.sql + <<-SQL
    CREATE TABLE invoices (id INTEGER PRIMARY KEY, owner_id INTEGER NOT NULL, state TEXT NOT NULL, recipient TEXT) STRICT;

    SQL

  struct UserID < Punch::TypedID
  end

  struct InvoiceID < Punch::TypedID
  end

  struct Actor
    include Punch::Auth::Actor

    getter id : UserID

    def initialize(@id)
    end

    def self.load(principal : Punch::Auth::Principal, db : Punch::Reader | Punch::Writer) : self?
      new(principal.user_id(UserID))
    end
  end

  enum Priority
    Normal
    Urgent
  end

  enum State
    Draft
    Sent
  end

  # Only an invoice's owner sees it or acts on it.
  struct Owner
    include Punch::Policy

    def self.check(actor : Actor, db : Punch::Reader | Punch::Writer, *, invoice_id : InvoiceID) : Punch::Policy::Decision
      owner = db.query_one?("SELECT owner_id FROM invoices WHERE id = ?", invoice_id.value, &.read(Int64)) || return not_found
      owner == actor.id.value ? allow : not_found
    end
  end

  struct Invoice
    getter id : InvoiceID
    getter state : String
    getter recipient : String?

    def initialize(@id, @state, @recipient)
    end
  end

  @[Punch::Status(200)]
  struct Done
    include JSON::Serializable

    def initialize
    end
  end

  @[Punch::Status(404)]
  struct Missing
    include JSON::Serializable

    def initialize
    end
  end

  @[Punch::Status(409)]
  struct AlreadySent
    include JSON::Serializable

    def initialize
    end
  end

  def self.invoice(db : Punch::Reader | Punch::Writer, id : InvoiceID) : Invoice?
    db.query_one?("SELECT state, recipient FROM invoices WHERE id = ?", id.value) do |row|
      Invoice.new(id, row.read(String), row.read(String?))
    end
  end

  module Invoices
    @[Punch::Authorize(Owner)]
    @[Punch::RateLimit(30, per: 1.hour, by: :actor)]
    @[Punch::Idempotency(:required)]
    struct Send < Punch::Command
      struct Input
        include Punch::Input

        @[Punch::PathParam]
        getter invoice_id : InvoiceID

        getter recipient : Punch::Email
        getter note : String?
        getter? copy_to_me : Bool = false
        getter priority : Priority
        getter send_at : Time?
        getter copies : Int32 = 1
      end

      def call(input : Input, db : Punch::Writer, actor : Actor, grant : Punch::Grant(Send)) : Done | AlreadySent
        return AlreadySent.new if ActionBlocksSpec.invoice(db, input.invoice_id).try(&.state) == "sent"

        db.exec("UPDATE invoices SET state = 'sent', recipient = ? WHERE id = ?", input.recipient.value, input.invoice_id.value)
        Done.new
      end
    end

    @[Punch::Authorize(Owner)]
    struct Destroy < Punch::Command
      struct Input
        include Punch::Input

        @[Punch::PathParam]
        getter invoice_id : InvoiceID
      end

      def call(input : Input, db : Punch::Writer, actor : Actor, grant : Punch::Grant(Destroy)) : Nil
        db.exec("DELETE FROM invoices WHERE id = ?", input.invoice_id.value)
      end
    end

    # Holds no markdown of its form: an agent's refusal is a problem.
    @[Punch::Authorize(Owner)]
    struct Archive < Punch::Command
      struct Input
        include Punch::Input

        @[Punch::PathParam]
        getter invoice_id : InvoiceID

        getter reason : String
      end

      def call(input : Input, db : Punch::Writer, actor : Actor, grant : Punch::Grant(Archive)) : Nil
      end
    end

    @[Punch::Status(200)]
    struct InvoiceView
      include Punch::Component

      def initialize(@invoice : Invoice)
      end

      def view(v : Punch::View) : Nil
        v.document("Invoice #{@invoice.id.value}") do
          v.h1 "Invoice #{@invoice.id.value}"
          v.p "State: #{@invoice.state}"
          if @invoice.state == "draft"
            v.form(Send.action(invoice_id: @invoice.id), values: {recipient: Punch::Email.parse("ada@example.org").as(Punch::Email), copies: 2}) do |form|
              form.field :recipient, hint: "Invoices go *here*"
              form.field :note, as: :textarea
              form.field :copy_to_me
              form.field :priority
              form.field :send_at
              form.field :copies, as: :hidden
              form.submit "Send invoice"
            end
          end
          v.form(Destroy.action(invoice_id: @invoice.id), aria: {label: "Delete invoice #{@invoice.id.value}"}) do |form|
            form.submit "Delete"
          end
        end
      end
    end

    @[Punch::AgentReadable]
    @[Punch::Forms(Send, Destroy)]
    @[Punch::Authorize(Owner)]
    struct ShowPage < Punch::Page
      struct Input
        include Punch::Input

        @[Punch::PathParam]
        getter invoice_id : InvoiceID
      end

      def call(input : Input, db : Punch::Reader, actor : Actor, grant : Punch::Grant(ShowPage)) : InvoiceView | Missing
        found = ActionBlocksSpec.invoice(db, input.invoice_id)
        found ? InvoiceView.new(found) : Missing.new
      end

      def self.redirect(result : Nil) : Punch::Href
        IndexPage.href
      end
    end

    struct ArchiveView
      include Punch::Component

      def initialize(@id : InvoiceID)
      end

      def view(v : Punch::View) : Nil
        v.document("Archive") do
          v.form(Archive.action(invoice_id: @id)) do |form|
            form.field :reason
            form.submit "Archive"
          end
        end
      end
    end

    # People archive here; agents see the form on the summary page.
    @[Punch::Authorize(Owner)]
    struct ArchivePage < Punch::Page
      alias Input = ShowPage::Input

      def call(input : Input, db : Punch::Reader, actor : Actor, grant : Punch::Grant(ArchivePage)) : ArchiveView
        ArchiveView.new(input.invoice_id)
      end
    end

    @[Punch::AgentReadable]
    @[Punch::Authorize(Owner)]
    struct SummaryPage < Punch::Page
      alias Input = ShowPage::Input

      def call(input : Input, db : Punch::Reader, actor : Actor, grant : Punch::Grant(SummaryPage)) : ArchiveView
        ArchiveView.new(input.invoice_id)
      end
    end

    struct Filter
      include Punch::Input

      getter state : State?

      def initialize(@state : State? = nil)
      end
    end

    struct ListView
      include Punch::Component

      def initialize(@input : IndexPage::Input)
      end

      def view(v : Punch::View) : Nil
        v.document("Invoices") do
          v.h1 "Invoices"
          v.filter_form(IndexPage, @input) do |form|
            form.fields(:filter, Filter, &.field(:state))
            form.field :limit, as: :hidden
            form.submit "Filter"
          end
        end
      end
    end

    @[Punch::AgentReadable]
    @[Punch::Authorize(Punch::SignedIn)]
    struct IndexPage < Punch::Page
      struct Input
        include Punch::Input

        getter filter : Filter?
        getter limit : Int32 = 20
      end

      def call(input : Input, db : Punch::Reader, actor : Actor, grant : Punch::Grant(IndexPage)) : ListView
        ListView.new(input)
      end
    end
  end

  def self.with_db(&)
    path = File.tempname("action-blocks-spec", ".sql")
    File.write(path, SQL)
    previous = Punch::Spec.schema
    Punch::Spec.schema = path
    begin
      Punch::Spec.db.write do |db|
        db.exec("INSERT INTO users (id, name) VALUES (1, 'Ada'), (2, 'Grace')")
        db.exec("INSERT INTO invoices (id, owner_id, state) VALUES (1, 1, 'draft'), (2, 2, 'draft'), (3, 1, 'sent')")
      end
      yield
    ensure
      Punch::Spec.schema = previous
      File.delete(path)
    end
  end

  def self.client : Punch::Spec::Client
    Punch::Spec::Client.new(Punch::Routing::Router.new(Punch::Spec.db), openapi: nil)
  end

  def self.id(value : Int32) : InvoiceID
    InvoiceID.parse(value).as(InvoiceID)
  end

  def self.agent(user : Int32 = 1) : HTTP::Headers
    Punch::Spec.bearer(Punch::Spec.api_token(UserID.parse(user).as(UserID)))
  end

  def self.state(id : Int32) : String?
    Punch::Spec.db.read(&.query_one?("SELECT state FROM invoices WHERE id = ?", id, &.read(String)))
  end
end

describe "Action blocks" do
  it "describes each form the page shows, as the form would send it" do
    ActionBlocksSpec.with_db do
      page = ActionBlocksSpec.client.read(ActionBlocksSpec::Invoices::ShowPage.href(invoice_id: ActionBlocksSpec.id(1)), headers: ActionBlocksSpec.agent)
      page.content_type.should eq("text/markdown")
      body = page.body
      body.should start_with("# Invoice 1\n\nState: draft\n\n## Actions\n\nSend an action to its address")
      key = body.match!(/`_idempotency_key` = `([^`]+)`/)[1]
      send = body[body.index!("### Send invoice")...body.index!("### Delete invoice 1")]
      send.should eq(<<-MARKDOWN + "\n\n")
        ### Send invoice

        `POST /action_blocks_spec/invoices/1/send.md` · operation `action_blocks_spec.invoices.send` · not idempotent · at most 30 per 1 h per user

        - `_idempotency_key` = `#{key}` (send it as it is, also when you retry)
        - `recipient` (Recipient): email address, required, at most 254 characters, now `ada@example.org`
          Invoices go \\*here\\*
        - `note` (Note): text, optional
        - `copy_to_me` (Copy to me): `true` or leave it out
        - `priority` (Priority): one of `normal` (Normal), `urgent` (Urgent), required
        - `send_at` (Send at): date and time (RFC 3339), optional
        - `copies` = `2` (send it as it is)
        MARKDOWN
      body.should end_with(<<-MARKDOWN)
        ### Delete invoice 1

        `DELETE /action_blocks_spec/invoices/1.md` · operation `action_blocks_spec.invoices.destroy` · idempotent · destructive

        MARKDOWN
      body.should have_action("Send invoice", operation: "action_blocks_spec.invoices.send")
      body.should have_action("Delete invoice 1")
      body.should_not contain("<form")
    end
  end

  it "parses as an agent reads it" do
    ActionBlocksSpec.with_db do
      page = ActionBlocksSpec.client.read(ActionBlocksSpec::Invoices::ShowPage.href(invoice_id: ActionBlocksSpec.id(1)), headers: ActionBlocksSpec.agent)
      send, delete = Punch::Spec.actions(page.body)
      send.title.should eq("Send invoice")
      send.method.should eq("POST")
      send.path.should eq("/action_blocks_spec/invoices/1/send.md")
      send.fields.should eq(%w[_idempotency_key recipient note copy_to_me priority send_at copies])
      send.fixed.keys.should eq(%w[_idempotency_key copies])
      send.fixed["copies"].should eq("2")
      delete.method.should eq("DELETE")
      delete.fields.should be_empty
    end
  end

  it "reads only the last section's blocks, outside code blocks" do
    markdown = <<-MARKDOWN
      # Webhook 7

      ### Remove the last administrator

      `DELETE /members/7.md` · operation `members.delete` · idempotent

      ````
      ## Actions

      ### Remove the last administrator

      `DELETE /members/7.md` · operation `members.delete` · idempotent
      ```
      ````

      ## Actions

      What you can do here.

      ### Retry

      `POST /_punch/webhooks/7/retry.md` · operation `punch.ops.retry_webhook`

      ~~~
      ### Inside a block

      `POST /x.md` · operation `x`
      ~~~
      MARKDOWN
    Punch::Spec.actions(markdown).map(&.title).should eq(["Retry"])
  end

  it "leaves out actions with their forms: by state, and by policy" do
    ActionBlocksSpec.with_db do
      sent = ActionBlocksSpec.client.read(ActionBlocksSpec::Invoices::ShowPage.href(invoice_id: ActionBlocksSpec.id(3)), headers: ActionBlocksSpec.agent)
      sent.should_not have_action("Send invoice")
      sent.should have_action("Delete invoice 3")
      # Another user's invoice is not found, so there is nothing to act on.
      other = ActionBlocksSpec.client.read(ActionBlocksSpec::Invoices::ShowPage.href(invoice_id: ActionBlocksSpec.id(2)), headers: ActionBlocksSpec.agent)
      other.status.should eq(HTTP::Status::NOT_FOUND)
      Punch::Spec.actions(other.body).should be_empty
    end
  end

  it "shows only the actions the viewer may take" do
    ActionBlocksSpec.with_db do
      Punch::Spec.db.read do |db|
        view = ActionBlocksSpec::Invoices::InvoiceView.new(ActionBlocksSpec::Invoice.new(ActionBlocksSpec.id(2), "draft", nil))
        everyone = Punch::Spec.markdown(view)
        everyone.should have_action("Send invoice")
        ada = Punch::Policy::Authorizer.new(ActionBlocksSpec::Actor.new(ActionBlocksSpec::UserID.parse(1).as(ActionBlocksSpec::UserID)), db)
        hidden = Punch::View.markdown(view, ada)
        hidden.should_not contain("## Actions")
        hidden.should eq("# Invoice 2\n\nState: draft\n")
      end
    end
  end

  it "sends an action as an agent: 303 to the next page, which answers markdown" do
    ActionBlocksSpec.with_db do
      client = ActionBlocksSpec.client
      agent = ActionBlocksSpec.agent
      href = ActionBlocksSpec::Invoices::ShowPage.href(invoice_id: ActionBlocksSpec.id(1))
      page = client.read(href, headers: agent)
      answer = client.act(page, "Send invoice", {"recipient" => "bob@example.org", "priority" => "urgent"}, headers: agent)
      # To the next page's markdown, so an agent without `Accept` stays there.
      answer.should redirect_to(href.markdown_url)
      answer.trace.root.attributes["punch.surface"].should eq("markdown")
      ActionBlocksSpec.state(1).should eq("sent")
      # A retry with the same key gets the first answer, without sending again.
      again = client.act(page, "Send invoice", {"recipient" => "bob@example.org", "priority" => "urgent"}, headers: agent)
      again.should redirect_to(href.markdown_url)
      again.trace.root["punch.idempotency"].should eq("replayed")
      after = client.read(answer.headers["Location"], headers: agent)
      after.body.should start_with("# Invoice 1\n\nState: sent\n")
      after.should_not have_action("Send invoice")
      deleted = client.act(after, "Delete invoice 1", headers: agent)
      deleted.should redirect_to(ActionBlocksSpec::Invoices::IndexPage.href.markdown_url)
      ActionBlocksSpec.state(1).should be_nil
    end
  end

  it "answers a refusal with the page again in markdown, the errors in the action" do
    ActionBlocksSpec.with_db do
      client = ActionBlocksSpec.client
      agent = ActionBlocksSpec.agent
      page = client.read(ActionBlocksSpec::Invoices::ShowPage.href(invoice_id: ActionBlocksSpec.id(1)), headers: agent)
      refused = client.act(page, "Send invoice", {"recipient" => "nope", "priority" => "soon"}, headers: agent)
      refused.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
      refused.content_type.should eq("text/markdown")
      refused.body.should contain("- `recipient` (Recipient): email address, required, at most 254 characters, now `nope`\n  Invoices go \\*here\\*\n  - Problem: Is not an email address. (`invalid_email`)\n")
      refused.body.should contain("- `priority` (Priority): one of `normal` (Normal), `urgent` (Urgent), required\n  - Problem: Is not one of the choices. (`invalid_choice`)\n")
      ActionBlocksSpec.state(1).should eq("draft")
      # The refused form keeps its key, so the corrected one runs.
      fixed = client.act(refused, "Send invoice", {"recipient" => "bob@example.org", "priority" => "normal"}, headers: agent)
      fixed.status.should eq(HTTP::Status::SEE_OTHER)
      ActionBlocksSpec.state(1).should eq("sent")
    end
  end

  it "states a failure of the Command at the top of its action" do
    ActionBlocksSpec.with_db do
      client = ActionBlocksSpec.client
      agent = ActionBlocksSpec.agent
      page = client.read(ActionBlocksSpec::Invoices::ShowPage.href(invoice_id: ActionBlocksSpec.id(1)), headers: agent)
      Punch::Spec.db.write(&.exec("UPDATE invoices SET state = 'sent' WHERE id = 1"))
      conflict = client.act(page, "Send invoice", {"recipient" => "bob@example.org", "priority" => "normal"}, headers: agent)
      conflict.status.should eq(HTTP::Status::CONFLICT)
      conflict.content_type.should eq("text/markdown")
      # The page in its new state no longer offers it, so the refusal
      # opens the actions.
      conflict.should_not have_action("Send invoice")
      conflict.body.should contain("## Actions\n\nProblem: `already_sent`\n\n")
    end
  end

  it "answers a refusal as a markdown problem when the holding page is not agent-readable" do
    ActionBlocksSpec.with_db do
      client = ActionBlocksSpec.client
      agent = ActionBlocksSpec.agent
      page = client.read(ActionBlocksSpec::Invoices::SummaryPage.href(invoice_id: ActionBlocksSpec.id(1)), headers: agent)
      page.should have_action("Archive")
      refused = client.act(page, "Archive", headers: agent)
      refused.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
      refused.content_type.should eq("text/markdown")
      refused.body.should contain("Problem: `invalid_input`")
      refused.body.should contain("- `reason`: Is required. `required`")
      # A browser gets the holding page.
      browser = client.sign_in(ActionBlocksSpec::UserID.parse(1).as(ActionBlocksSpec::UserID))
      browser.submit(ActionBlocksSpec::Invoices::Archive.action(invoice_id: ActionBlocksSpec.id(1)), form: {"reason" => ""}).content_type.should eq("text/html")
    end
  end

  it "keeps an agent that sends no Accept on markdown, by the .md URLs" do
    ActionBlocksSpec.with_db do
      client = ActionBlocksSpec.client
      agent = ActionBlocksSpec.agent
      agent["Accept"] = "*/*"
      href = ActionBlocksSpec::Invoices::ShowPage.href(invoice_id: ActionBlocksSpec.id(1))
      page = client.get(href.markdown_url, headers: agent)
      page.content_type.should eq("text/markdown")
      refused = client.act(page, "Send invoice", {"recipient" => "bob@example.org"}, headers: agent)
      refused.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
      refused.content_type.should eq("text/markdown")
      refused.body.should contain("- `priority` (Priority):")
      sent = client.act(page, "Send invoice", {"recipient" => "bob@example.org", "priority" => "urgent"}, headers: agent)
      sent.should redirect_to("/action_blocks_spec/invoices/1.md")
      client.get(sent.headers["Location"], headers: agent).body.should start_with("# Invoice 1\n\nState: sent\n")
    end
  end

  it "describes a filter form as a GET with query parameters" do
    ActionBlocksSpec.with_db do
      client = ActionBlocksSpec.client
      agent = ActionBlocksSpec.agent
      page = client.read(ActionBlocksSpec::Invoices::IndexPage.href(filter: ActionBlocksSpec::Invoices::Filter.new(state: :sent)), headers: agent)
      page.body.should end_with(<<-MARKDOWN)
        ### Filter

        `GET /action_blocks_spec/invoices.md` · operation `action_blocks_spec.invoices.index_page` · safe

        The fields go in the query string.

        - `filter[state]` (State): one of `draft` (Draft), `sent` (Sent), optional, now `sent`

        MARKDOWN
      filtered = client.act(page, "Filter", {"filter[state]" => "draft"}, headers: agent)
      filtered.status.should eq(HTTP::Status::OK)
      filtered.body.should contain("now `draft`")
    end
  end

  it "writes the phrases in the reader's language, names and codes as they are" do
    ActionBlocksSpec.with_db do
      headers = ActionBlocksSpec.agent
      headers["Accept-Language"] = "de"
      page = ActionBlocksSpec.client.read(ActionBlocksSpec::Invoices::ShowPage.href(invoice_id: ActionBlocksSpec.id(1)), headers: headers)
      page.body.should contain("## Aktionen")
      page.body.should contain("`POST /action_blocks_spec/invoices/1/send.md` · Operation `action_blocks_spec.invoices.send` · nicht idempotent · höchstens 30 pro 1 h je Benutzer")
      page.body.should contain("- `recipient` (Recipient): E-Mail-Adresse, Pflicht, höchstens 254 Zeichen, jetzt `ada@example.org`")
    end
  end
end
