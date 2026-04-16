import { Controller } from "@hotwired/stimulus"

export default class AutoSubmitController extends Controller {
  submit(event) {
    const form = event.target.form
    form.requestSubmit ? form.requestSubmit() : form.submit();
  }
}
