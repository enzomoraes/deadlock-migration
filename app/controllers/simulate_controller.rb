class SimulateController < ApplicationController
  def create
    ActiveRecord::Base.transaction do
      # 1. INSERT into teams → acquires ROW EXCLUSIVE on teams
      team = Team.create!(name: "team-#{SecureRandom.uuid}")
      Rails.logger.info "[SIMULATE] Team created (id=#{team.id}). Sleeping 15s — run the FK migration now!"

      # 2. Sleep to allow the migration to acquire SHARE ROW EXCLUSIVE on tickets
      sleep 15

      # 3. INSERT into tickets → tries ROW EXCLUSIVE on tickets
      #    If migration already holds SHARE ROW EXCLUSIVE on tickets → DEADLOCK
      Rails.logger.info "[SIMULATE] Woke up. Attempting to create ticket..."
      ticket = Ticket.create!(title: "ticket-#{SecureRandom.uuid}", team_id: team.id)

      Rails.logger.info "[SIMULATE] Ticket created (id=#{ticket.id}). No deadlock this time."
      render json: { team_id: team.id, ticket_id: ticket.id }
    end
  rescue ActiveRecord::Deadlocked => e
    Rails.logger.error "[SIMULATE] DEADLOCK DETECTED: #{e.message}"
    render json: { error: "deadlock_detected", message: e.message }, status: :conflict
  end
end
