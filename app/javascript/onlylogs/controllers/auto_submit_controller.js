import { Controller } from "@hotwired/stimulus"

export default class AutoSubmitController extends Controller {
  submit(event) {
    const form = event.target.form
    if (form.requestSubmit) {
      form.requestSubmit()
    } else {
      form.submit()
    }
  }
}
