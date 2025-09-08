class HomeController < ApplicationController
  def show
    Rails.logger.debug { Faker::Lorem.sentence }
    Rails.logger.info { "We have #{Book.count} books" }
    Rails.logger.error { Faker::Lorem.sentence }
  end
end
