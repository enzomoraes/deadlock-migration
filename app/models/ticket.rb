class Ticket < ApplicationRecord
  belongs_to :team, optional: true
end
