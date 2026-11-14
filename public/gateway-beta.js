// Generated from frontend/ by scripts/build-frontend.sh. Do not edit.
(() => {
  var __typeError = (msg) => {
    throw TypeError(msg);
  };
  var __accessCheck = (obj, member, msg) => member.has(obj) || __typeError("Cannot " + msg);
  var __privateGet = (obj, member, getter) => (__accessCheck(obj, member, "read from private field"), getter ? getter.call(obj) : member.get(obj));
  var __privateAdd = (obj, member, value) => member.has(obj) ? __typeError("Cannot add the same private member more than once") : member instanceof WeakSet ? member.add(obj) : member.set(obj, value);
  var __privateSet = (obj, member, value, setter) => (__accessCheck(obj, member, "write to private field"), setter ? setter.call(obj, value) : member.set(obj, value), value);

  // build/dev/javascript/prelude.mjs
  var CustomType = class {
    withFields(fields) {
      let properties = Object.keys(this).map(
        (label) => label in fields ? fields[label] : this[label]
      );
      return new this.constructor(...properties);
    }
  };
  var List = class {
    static fromArray(array, tail) {
      return toList(array, tail);
    }
    [Symbol.iterator]() {
      return new ListIterator(this);
    }
    toArray() {
      return [...this];
    }
    atLeastLength(desired) {
      let current = this;
      while (desired-- > 0 && current) current = current.tail;
      return current !== void 0;
    }
    hasLength(desired) {
      let current = this;
      while (desired-- > 0 && current) current = current.tail;
      return desired === -1 && current instanceof Empty;
    }
    countLength() {
      let current = this;
      let length2 = 0;
      while (current) {
        current = current.tail;
        length2++;
      }
      return length2 - 1;
    }
  };
  function toList(elements, tail) {
    let t = tail || List$Empty$const;
    for (let i = elements.length - 1; i >= 0; --i) {
      t = new NonEmpty(elements[i], t);
    }
    return t;
  }
  var _current;
  var ListIterator = class {
    constructor(current) {
      __privateAdd(this, _current);
      __privateSet(this, _current, current);
    }
    next() {
      if (__privateGet(this, _current) instanceof Empty) {
        return { done: true };
      } else {
        let { head, tail } = __privateGet(this, _current);
        __privateSet(this, _current, tail);
        return { value: head, done: false };
      }
    }
  };
  _current = new WeakMap();
  var Empty = class extends List {
  };
  var List$Empty$const = new Empty();
  var NonEmpty = class extends List {
    constructor(head, tail) {
      super();
      this.head = head;
      this.tail = tail;
    }
  };
  var Result = class _Result extends CustomType {
    static isResult(data) {
      return data instanceof _Result;
    }
  };
  var Ok = class extends Result {
    constructor(value) {
      super();
      this[0] = value;
    }
    isOk() {
      return true;
    }
  };
  var Error2 = class extends Result {
    constructor(detail) {
      super();
      this[0] = detail;
    }
    isOk() {
      return false;
    }
  };

  // build/dev/javascript/gleam_stdlib/dict.mjs
  var bits = 5;
  var mask = (1 << bits) - 1;
  var noElementMarker = Symbol();

  // build/dev/javascript/gleam_stdlib/gleam/option.mjs
  var None = class extends CustomType {
  };
  var Option$None$const = new None();

  // build/dev/javascript/gleam_stdlib/gleam/order.mjs
  var Lt = class extends CustomType {
  };
  var Order$Lt$const = new Lt();
  var Eq = class extends CustomType {
  };
  var Order$Eq$const = new Eq();
  var Gt = class extends CustomType {
  };
  var Order$Gt$const = new Gt();

  // build/dev/javascript/gleam_stdlib/gleam_stdlib.mjs
  function lowercase(string2) {
    return string2.toLowerCase();
  }
  var unicode_whitespaces = [
    " ",
    // Space
    "	",
    // Horizontal tab
    "\n",
    // Line feed
    "\v",
    // Vertical tab
    "\f",
    // Form feed
    "\r",
    // Carriage return
    "\x85",
    // Next line
    "\u2028",
    // Line separator
    "\u2029"
    // Paragraph separator
  ].join("");
  var trim_start_regex = /* @__PURE__ */ new RegExp(
    `^[${unicode_whitespaces}]*`
  );
  var trim_end_regex = /* @__PURE__ */ new RegExp(`[${unicode_whitespaces}]*$`);
  function trim_start(string2) {
    return string2.replace(trim_start_regex, "");
  }
  function trim_end(string2) {
    return string2.replace(trim_end_regex, "");
  }
  var MIN_I32 = -(2 ** 31);
  var MAX_I32 = 2 ** 31 - 1;
  var U32 = 2 ** 32;
  var MAX_SAFE = Number.MAX_SAFE_INTEGER;
  var MIN_SAFE = Number.MIN_SAFE_INTEGER;

  // build/dev/javascript/gleam_stdlib/gleam/list.mjs
  var Ascending = class extends CustomType {
  };
  var Sorting$Ascending$const = new Ascending();
  var Descending = class extends CustomType {
  };
  var Sorting$Descending$const = new Descending();

  // build/dev/javascript/gleam_stdlib/gleam/string_tree.mjs
  var All = class extends CustomType {
  };
  var Direction$All$const = new All();

  // build/dev/javascript/gleam_stdlib/gleam/string.mjs
  var Leading = class extends CustomType {
  };
  var Direction$Leading$const = new Leading();
  var Trailing = class extends CustomType {
  };
  var Direction$Trailing$const = new Trailing();
  function trim(string2) {
    let _pipe = string2;
    let _pipe$1 = trim_start(_pipe);
    return trim_end(_pipe$1);
  }

  // build/dev/javascript/fizzlayer_web/contact_ffi.mjs
  function install(formId, statusId, emailId, companyId, interestId, enterprise) {
    const form = document.getElementById(formId);
    const status = document.getElementById(statusId);
    if (!form || !status) return;
    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      const email = document.getElementById(emailId);
      const company = document.getElementById(companyId);
      const button = form.querySelector("button");
      status.classList.remove("error");
      const problem2 = problem(enterprise, email.checkValidity(), company.value);
      if (problem2) {
        status.classList.add("error");
        status.textContent = field_message_code(enterprise, problem2);
        (problem2 === "email" ? email : company).focus();
        return;
      }
      button.disabled = true;
      status.textContent = sending_label();
      try {
        const interest = enterprise ? document.getElementById(interestId).value : "";
        const response = await fetch("/api/contact", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            email: payload_email(email.value),
            company: payload_company(company.value),
            interest: payload_interest_for(enterprise, interest)
          })
        });
        const result = await response.json().catch(() => ({}));
        if (!response.ok) {
          const apiMessage = result.error && typeof result.error.message === "string" ? result.error.message : "";
          throw new Error(http_error(apiMessage));
        }
        status.textContent = success_text(enterprise, email.value);
        form.reset();
      } catch (error) {
        status.classList.add("error");
        status.textContent = error instanceof TypeError ? network_error() : error.message;
      } finally {
        button.disabled = false;
      }
    });
  }

  // build/dev/javascript/fizzlayer_web/contact.mjs
  var Enterprise = class extends CustomType {
  };
  var Form$Enterprise$const = new Enterprise();
  var GatewayBeta = class extends CustomType {
  };
  var Form$GatewayBeta$const = new GatewayBeta();
  var Email = class extends CustomType {
  };
  var FieldError$Email$const = new Email();
  var Company = class extends CustomType {
  };
  var FieldError$Company$const = new Company();
  function form_named(enterprise) {
    if (enterprise) {
      return Form$Enterprise$const;
    } else {
      return Form$GatewayBeta$const;
    }
  }
  function validate(form, email_valid, company) {
    if (form instanceof Enterprise) {
      if (email_valid) {
        let $ = trim(company) === "";
        if ($) {
          return new Error2(FieldError$Company$const);
        } else {
          return new Ok(void 0);
        }
      } else {
        return new Error2(FieldError$Email$const);
      }
    } else {
      if (email_valid) {
        let $ = trim(company) === "";
        if ($) {
          return new Error2(FieldError$Company$const);
        } else {
          return new Ok(void 0);
        }
      } else {
        return new Error2(FieldError$Email$const);
      }
    }
  }
  function problem(enterprise, email_valid, company) {
    let $ = validate(form_named(enterprise), email_valid, company);
    if ($ instanceof Ok) {
      return "";
    } else if ($[0] instanceof Email) {
      return "email";
    } else {
      return "company";
    }
  }
  function field_message(form, error) {
    if (form instanceof Enterprise) {
      if (error instanceof Email) {
        return "Enter a valid work email.";
      } else {
        return "Enter your company name.";
      }
    } else if (error instanceof Email) {
      return "Enter a valid email address.";
    } else {
      return "Enter your name or company.";
    }
  }
  function field_message_code(enterprise, code) {
    let form = form_named(enterprise);
    if (code === "email") {
      return field_message(form, FieldError$Email$const);
    } else if (code === "company") {
      return field_message(form, FieldError$Company$const);
    } else {
      return "";
    }
  }
  function sending_label() {
    return "Sending\u2026";
  }
  function success_message(form, email) {
    let address = lowercase(trim(email));
    if (form instanceof Enterprise) {
      return "Thanks. We'll be in touch at " + address + ".";
    } else {
      return "Saved for " + address + ". This does not create a gateway or reserve a plan.";
    }
  }
  function success_text(enterprise, email) {
    return success_message(form_named(enterprise), email);
  }
  function payload_email(email) {
    return trim(email);
  }
  function payload_company(company) {
    return trim(company);
  }
  function payload_interest(form, interest) {
    if (form instanceof Enterprise) {
      return trim(interest);
    } else {
      return "Gateway private beta";
    }
  }
  function payload_interest_for(enterprise, interest) {
    return payload_interest(form_named(enterprise), interest);
  }
  function http_error(api_message) {
    if (api_message === "") {
      return "Something went wrong. Try again.";
    } else {
      return api_message;
    }
  }
  function network_error() {
    return "Could not reach Fizzlayer. Check your connection and try again.";
  }
  function install_gateway_beta() {
    return install(
      "beta-form",
      "beta-status",
      "beta-email",
      "beta-company",
      "",
      false
    );
  }

  // entries/gateway-beta.js
  install_gateway_beta();
})();
