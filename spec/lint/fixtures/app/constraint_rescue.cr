# Fixture for Punch/ConstraintRescue: rescuing ConstraintError in app code.
module Shop
  def self.add(db : Punch::Writer) : Bool
    db.exec("INSERT INTO tags (name) VALUES ('x')")
    true
  rescue Punch::Database::ConstraintError # expect
    false
  end

  def self.other(db : Punch::Writer) : Nil
    begin
      db.exec("DELETE FROM tags")
    rescue ex : IO::Error | Database::ConstraintError # expect
      nil
    end
  end

  def self.fine(db : Punch::Writer) : Nil
    db.exec("DELETE FROM tags")
  rescue ex : Punch::Database::BusyError
    raise ex
  end
end
