# Fixture for Punch/EventsHandle: events and jobs handles made by hand.
module Shop
  def self.sneak(db : Punch::Writer) : Nil
    Punch::Events(OrderPlaced).for_transaction(db).publish(OrderPlaced.new) # expect
    Events(OrderPlaced | OrderShipped).for_transaction(db)                  # expect
    Punch::Jobs(Remind).for_transaction(db).enqueue(Remind.new)             # expect
    Punch::Spec.events(Orders::Place, db)
    Punch::Spec.jobs(Orders::Place, db)
    Other(OrderPlaced).for_transaction(db)
  end
end
