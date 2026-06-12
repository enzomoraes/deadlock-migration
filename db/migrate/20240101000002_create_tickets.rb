class CreateTickets < ActiveRecord::Migration[7.1]
  def change
    create_table :tickets do |t|
      t.string :title, null: false
      t.bigint :team_id
      t.timestamps
    end
  end
end
