import contact.{Company, Email, Enterprise, GatewayBeta}
import gleeunit/should

pub fn invalid_email_is_reported_before_a_blank_company_test() {
  contact.validate(Enterprise, False, "   ")
  |> should.equal(Error(Email))
  contact.validate(GatewayBeta, True, "  ")
  |> should.equal(Error(Company))
  contact.validate(Enterprise, True, " Acme ")
  |> should.equal(Ok(Nil))
}

pub fn field_messages_match_each_form_test() {
  contact.field_message(Enterprise, Email)
  |> should.equal("Enter a valid work email.")
  contact.field_message(Enterprise, Company)
  |> should.equal("Enter your company name.")
  contact.field_message(GatewayBeta, Email)
  |> should.equal("Enter a valid email address.")
  contact.field_message(GatewayBeta, Company)
  |> should.equal("Enter your name or company.")
  contact.problem(True, False, "Acme") |> should.equal("email")
  contact.field_message_code(False, "company")
  |> should.equal("Enter your name or company.")
}

pub fn success_text_lowercases_the_address_test() {
  contact.success_message(Enterprise, "  Ada@Example.com ")
  |> should.equal("Thanks. We'll be in touch at ada@example.com.")
  contact.success_message(GatewayBeta, "Ada@Example.com")
  |> should.equal(
    "Saved for ada@example.com. This does not create a gateway or reserve a plan.",
  )
}

pub fn payload_trims_fields_and_fixes_the_beta_interest_test() {
  contact.payload_email("  Ada@Example.com ") |> should.equal("Ada@Example.com")
  contact.payload_company("  Acme  ") |> should.equal("Acme")
  contact.payload_interest(Enterprise, "  Cold rooms ")
  |> should.equal("Cold rooms")
  contact.payload_interest(GatewayBeta, "ignored")
  |> should.equal("Gateway private beta")
}

pub fn http_and_network_errors_use_the_existing_sentences_test() {
  contact.http_error("") |> should.equal("Something went wrong. Try again.")
  contact.http_error("Try later.") |> should.equal("Try later.")
  contact.network_error()
  |> should.equal(
    "Could not reach Fizzlayer. Check your connection and try again.",
  )
  contact.sending_label() |> should.equal("Sending…")
}
