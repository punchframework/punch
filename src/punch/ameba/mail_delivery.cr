module Ameba::Rule::Punch
  # Keeps mail behind `Punch::Mailer`: a mail is a component that includes
  # `Punch::Mail`, delivered by a job. Outside `src/punch/mail/` this
  # reports `Carbon::Email` (Carbon's own email class, whose ECR templates
  # and `deliver` bypass Punch), Carbon's development and SMTP adapters
  # (unsafe in parallel and silent on failure), and any `deliver_later`,
  # which spawns a fiber instead of going through the outbox. Carbon's
  # provider adapters stay allowed, wrapped in
  # `Punch::Mailer::CarbonAdapter`.
  #
  # ```
  # Punch/MailDelivery:
  #   Enabled: true
  # ```
  class MailDelivery < Base
    properties do
      since_version "1.7.0"
      description "Reports mail sent around Punch::Mailer"
    end

    MSG = "Send mail through Punch::Mailer: a struct that includes Punch::Mail, delivered from a job with Punch::Mailer.deliver (lib/punch/docs/mail.md)"

    FORBIDDEN = {"Email", "DevAdapter", "SmtpAdapter"}

    def test(source : Source)
      return if source.path.includes?("src/punch/mail/")

      visitor = Finder.new
      source.ast.accept(visitor)
      visitor.nodes.each { |node| issue_for node, MSG }
    end

    private class Finder < Crystal::Visitor
      getter nodes = [] of Crystal::ASTNode

      def visit(node : Crystal::Path)
        names = node.names
        nodes << node if names.size >= 2 && names[0] == "Carbon" && FORBIDDEN.includes?(names[1])
        true
      end

      def visit(node : Crystal::Call)
        nodes << node if node.name == "deliver_later"
        true
      end

      def visit(node : Crystal::ASTNode)
        true
      end
    end
  end
end
