Onlylogs::Engine.routes.draw do
  root "logs#index"
  resources :logs, only: [:index]
  get "download", to: "logs#download", as: :download_log
  resources :queries, only: [:index, :create, :show, :update, :destroy]
end
