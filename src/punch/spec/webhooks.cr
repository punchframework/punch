module Punch::Spec
  # The inbound webhook invocations in this example's database, oldest
  # first, each in its state (`Punch::Webhook::Invocation`), optionally
  # only those of *provider* (the name of `@[Punch::Webhook::Provider]`):
  #
  # ```
  # client.deliver_webhook(Payments::Provider::Receive.path, body, secret: SECRET)
  # Punch::Spec.perform_jobs
  # Punch::Spec.webhooks.last.should be_a(Punch::Webhook::Invocation::Processed)
  # ```
  def self.webhooks(provider : String? = nil) : Array(Webhook::Invocation::Any)
    db.read do |reader|
      ids = reader.query_all("SELECT id FROM punch_webhooks WHERE ?1 IS NULL OR provider = ?1 ORDER BY id", provider,
        name: "Punch::Spec.webhooks", &.read(Int64))
      ids.compact_map { |id| Webhook::Invocations.load(reader, id) }
    end
  end
end
