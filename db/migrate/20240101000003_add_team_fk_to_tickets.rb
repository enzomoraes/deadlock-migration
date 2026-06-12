class AddTeamFkToTickets < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def up
    # Acquires SHARE ROW EXCLUSIVE on tickets (child), then tries SHARE ROW EXCLUSIVE on teams (parent).
    # If a transaction holds ROW EXCLUSIVE on teams and is waiting for tickets, this creates a deadlock.
    add_foreign_key :tickets, :teams, column: :team_id, validate: false
    
    # disable_ddl_transaction! is required because CREATE INDEX CONCURRENTLY cannot run inside a transaction.
    # Side effect: each statement auto-commits immediately, so a crash mid-migration leaves the DB in a partial state.
    add_index :tickets, :team_id, algorithm: :concurrently
  end

  def down
    remove_index :tickets, :team_id, algorithm: :concurrently
    remove_foreign_key :tickets, column: :team_id
  end
end
