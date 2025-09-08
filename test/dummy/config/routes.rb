Rails.application.routes.draw do
  mount Onlylogs::Engine => "/onlylogs"

  root "home#show"
end
