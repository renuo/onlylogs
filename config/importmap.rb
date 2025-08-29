pin "application", to: "onlylogs/application.js", preload: true
pin "@rails/actioncable", to: "actioncable.esm.js"
pin "@hotwired/stimulus", to: "stimulus.min.js", preload: true
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js", preload: true
pin_all_from Onlylogs::Engine.root.join("app/javascript/onlylogs/controllers"), under: "controllers", to: "onlylogs/controllers"

