Rails.application.routes.draw do
  mount Onlylogs::Engine => "/onlylogs"

  root "home#show"
  get "logs/:file_path", to: "logs#show", as: :log_viewer
end
