import gleam/string

/// The two contact forms that post to `/api/contact`.
pub type Form {
  Enterprise
  GatewayBeta
}

pub type FieldError {
  Email
  Company
}

pub fn form_named(enterprise: Bool) -> Form {
  case enterprise {
    True -> Enterprise
    False -> GatewayBeta
  }
}

/// Email is checked first, then a blank company name. The browser decides
/// whether the email text itself is valid.
pub fn validate(
  form: Form,
  email_valid: Bool,
  company: String,
) -> Result(Nil, FieldError) {
  case form {
    Enterprise | GatewayBeta ->
      case email_valid {
        False -> Error(Email)
        True ->
          case string.trim(company) == "" {
            True -> Error(Company)
            False -> Ok(Nil)
          }
      }
  }
}

pub fn problem(enterprise: Bool, email_valid: Bool, company: String) -> String {
  case validate(form_named(enterprise), email_valid, company) {
    Ok(_) -> ""
    Error(Email) -> "email"
    Error(Company) -> "company"
  }
}

pub fn field_message(form: Form, error: FieldError) -> String {
  case form, error {
    Enterprise, Email -> "Enter a valid work email."
    Enterprise, Company -> "Enter your company name."
    GatewayBeta, Email -> "Enter a valid email address."
    GatewayBeta, Company -> "Enter your name or company."
  }
}

pub fn field_message_code(enterprise: Bool, code: String) -> String {
  let form = form_named(enterprise)
  case code {
    "email" -> field_message(form, Email)
    "company" -> field_message(form, Company)
    _ -> ""
  }
}

pub fn sending_label() -> String {
  "Sending…"
}

pub fn success_message(form: Form, email: String) -> String {
  let address = string.lowercase(string.trim(email))
  case form {
    Enterprise -> "Thanks. We'll be in touch at " <> address <> "."
    GatewayBeta ->
      "Saved for "
      <> address
      <> ". This does not create a gateway or reserve a plan."
  }
}

pub fn success_text(enterprise: Bool, email: String) -> String {
  success_message(form_named(enterprise), email)
}

pub fn payload_email(email: String) -> String {
  string.trim(email)
}

pub fn payload_company(company: String) -> String {
  string.trim(company)
}

pub fn payload_interest(form: Form, interest: String) -> String {
  case form {
    Enterprise -> string.trim(interest)
    GatewayBeta -> "Gateway private beta"
  }
}

pub fn payload_interest_for(enterprise: Bool, interest: String) -> String {
  payload_interest(form_named(enterprise), interest)
}

pub fn http_error(api_message: String) -> String {
  case api_message {
    "" -> "Something went wrong. Try again."
    message -> message
  }
}

pub fn network_error() -> String {
  "Could not reach Fizzlayer. Check your connection and try again."
}

pub fn install_enterprise() -> Nil {
  listen(
    "business-form",
    "business-status",
    "business-email",
    "business-company",
    "business-interest",
    True,
  )
}

pub fn install_gateway_beta() -> Nil {
  listen("beta-form", "beta-status", "beta-email", "beta-company", "", False)
}

@external(javascript, "./contact_ffi.mjs", "install")
fn listen(
  form_id: String,
  status_id: String,
  email_id: String,
  company_id: String,
  interest_id: String,
  enterprise: Bool,
) -> Nil
