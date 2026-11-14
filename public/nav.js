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
      let length = 0;
      while (current) {
        current = current.tail;
        length++;
      }
      return length - 1;
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

  // build/dev/javascript/fizzlayer_web/nav_ffi.mjs
  function install() {
    const navToggle = document.getElementById("nav-toggle");
    const navLinks = document.getElementById("nav-links");
    if (!navToggle || !navLinks) return;
    const apply = (eventName) => {
      const open = navLinks.classList.contains("open");
      const next = menu_open(open, eventName);
      navLinks.classList.toggle("open", next);
      navToggle.setAttribute("aria-expanded", String(next));
      if (menu_focus(open, eventName)) navToggle.focus();
    };
    navToggle.addEventListener("click", () => apply("toggle"));
    navLinks.addEventListener("click", (event) => {
      if (event.target.closest("a")) apply("link");
    });
    addEventListener("keydown", (event) => {
      if (event.key === "Escape") apply("escape");
    });
  }

  // build/dev/javascript/fizzlayer_web/nav.mjs
  var Menu = class extends CustomType {
    constructor(open, focus_toggle) {
      super();
      this.open = open;
      this.focus_toggle = focus_toggle;
    }
  };
  function next_menu(open, event) {
    if (event === "toggle") {
      return new Menu(!open, false);
    } else if (event === "link") {
      return new Menu(false, false);
    } else if (event === "escape") {
      if (open) {
        return new Menu(false, true);
      } else {
        return new Menu(open, false);
      }
    } else {
      return new Menu(open, false);
    }
  }
  function menu_open(open, event) {
    return next_menu(open, event).open;
  }
  function menu_focus(open, event) {
    return next_menu(open, event).focus_toggle;
  }
  function install2() {
    return install();
  }

  // entries/nav.js
  install2();
})();
