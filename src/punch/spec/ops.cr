module Punch::Spec
  @@ops : Ops::Store?
  @@ops_lock = Mutex.new

  # This example's `ops.db`: in memory, opened on first use, attached as
  # `Punch::Ops.current?`, and closed after the example. Once it is open,
  # the wide events of `Punch::Spec.client` requests and of
  # `perform_jobs` are recorded in it as `serve` would, at once rather
  # than in batches:
  #
  # ```
  # ops = Punch::Spec.ops
  # client.get("/boom")
  # ops.errors.first.exception.should eq("KeyError")
  # ```
  #
  def self.ops : Ops::Store
    @@ops_lock.synchronize do
      @@ops ||= begin
        database = Database.memory(name: "ops", config: Database::Config.new(readers: 2))
        Ops::Store.new(database).tap { |store| Ops.attach(store) }
      end
    end
  end

  # This example's ops store, if it was opened.
  def self.ops? : Ops::Store?
    @@ops_lock.synchronize { @@ops }
  end

  # Records wide events in this example's ops store, when one is open:
  # the spec side of `Ops::Sink`, without its fiber.
  class OpsEvents < Trace::EventSink
    def emit(event : Trace::Span) : Nil
      store = Spec.ops? || return
      Ops::Sink.capture(event).try { |capture| store.store([capture]) }
      store.store(Ops::Sink.tallies(event))
    end
  end

  # :nodoc:
  def self.close_ops : Nil
    store = @@ops_lock.synchronize { @@ops.tap { @@ops = nil } }
    return unless store

    Ops.detach
    store.database.close
  end
end

Spec.after_each { Punch::Spec.close_ops }
