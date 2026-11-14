import * as contact from "./contact.mjs";

export function install(formId, statusId, emailId, companyId, interestId, enterprise) {
  const form = document.getElementById(formId);
  const status = document.getElementById(statusId);
  if (!form || !status) return;
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const email = document.getElementById(emailId);
    const company = document.getElementById(companyId);
    const button = form.querySelector("button");
    status.classList.remove("error");
    const problem = contact.problem(enterprise, email.checkValidity(), company.value);
    if (problem) {
      status.classList.add("error");
      status.textContent = contact.field_message_code(enterprise, problem);
      (problem === "email" ? email : company).focus();
      return;
    }
    button.disabled = true;
    status.textContent = contact.sending_label();
    try {
      const interest = enterprise ? document.getElementById(interestId).value : "";
      const response = await fetch("/api/contact", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          email: contact.payload_email(email.value),
          company: contact.payload_company(company.value),
          interest: contact.payload_interest_for(enterprise, interest),
        }),
      });
      const result = await response.json().catch(() => ({}));
      if (!response.ok) {
        const apiMessage =
          result.error && typeof result.error.message === "string" ? result.error.message : "";
        throw new Error(contact.http_error(apiMessage));
      }
      status.textContent = contact.success_text(enterprise, email.value);
      form.reset();
    } catch (error) {
      status.classList.add("error");
      status.textContent =
        error instanceof TypeError ? contact.network_error() : error.message;
    } finally {
      button.disabled = false;
    }
  });
}
