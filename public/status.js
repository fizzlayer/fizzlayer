// Generated from frontend/ by scripts/build-frontend.sh. Do not edit.
(() => {
  var __defProp = Object.defineProperty;
  var __typeError = (msg) => {
    throw TypeError(msg);
  };
  var __defNormalProp = (obj, key, value) => key in obj ? __defProp(obj, key, { enumerable: true, configurable: true, writable: true, value }) : obj[key] = value;
  var __publicField = (obj, key, value) => __defNormalProp(obj, typeof key !== "symbol" ? key + "" : key, value);
  var __accessCheck = (obj, member, msg) => member.has(obj) || __typeError("Cannot " + msg);
  var __privateGet = (obj, member, getter) => (__accessCheck(obj, member, "read from private field"), getter ? getter.call(obj) : member.get(obj));
  var __privateAdd = (obj, member, value) => member.has(obj) ? __typeError("Cannot add the same private member more than once") : member instanceof WeakSet ? member.add(obj) : member.set(obj, value);
  var __privateSet = (obj, member, value, setter) => (__accessCheck(obj, member, "write to private field"), setter ? setter.call(obj, value) : member.set(obj, value), value);
  var __privateMethod = (obj, member, method) => (__accessCheck(obj, member, "access private method"), method);
  var __privateWrapper = (obj, member, setter, getter) => ({
    set _(value) {
      __privateSet(obj, member, value, setter);
    },
    get _() {
      return __privateGet(obj, member, getter);
    }
  });

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
    static fromArray(array3, tail) {
      return toList(array3, tail);
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
  function prepend(element4, tail) {
    return new NonEmpty(element4, tail);
  }
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
  var List$Empty = () => List$Empty$const;
  var NonEmpty = class extends List {
    constructor(head, tail) {
      super();
      this.head = head;
      this.tail = tail;
    }
  };
  var List$NonEmpty = (head, tail) => new NonEmpty(head, tail);
  var List$isNonEmpty = (value) => value instanceof NonEmpty;
  var List$NonEmpty$first = (value) => value.head;
  var List$NonEmpty$rest = (value) => value.tail;
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
  var Result$Ok = (value) => new Ok(value);
  var Result$isOk = (value) => value instanceof Ok;
  var Result$Ok$0 = (value) => value[0];
  var Error2 = class extends Result {
    constructor(detail) {
      super();
      this[0] = detail;
    }
    isOk() {
      return false;
    }
  };
  var Result$Error = (detail) => new Error2(detail);

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
  var Order$Lt = () => Order$Lt$const;
  var Eq = class extends CustomType {
  };
  var Order$Eq$const = new Eq();
  var Order$Eq = () => Order$Eq$const;
  var Gt = class extends CustomType {
  };
  var Order$Gt$const = new Gt();
  var Order$Gt = () => Order$Gt$const;

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
  function split2(x, substring) {
    if (substring === "") {
      return graphemes(x);
    } else {
      let _pipe = x;
      let _pipe$1 = identity(_pipe);
      let _pipe$2 = split(_pipe$1, substring);
      return map2(_pipe$2, identity);
    }
  }
  function concat_loop(loop$strings, loop$accumulator) {
    while (true) {
      let strings = loop$strings;
      let accumulator = loop$accumulator;
      if (strings instanceof Empty) {
        return accumulator;
      } else {
        let string5 = strings.head;
        let strings$1 = strings.tail;
        loop$strings = strings$1;
        loop$accumulator = accumulator + string5;
      }
    }
  }
  function concat2(strings) {
    return concat_loop(strings, "");
  }

  // build/dev/javascript/gleam_stdlib/gleam/dynamic/decode.mjs
  var Decoder = class extends CustomType {
    constructor(function$) {
      super();
      this.function = function$;
    }
  };
  function run(data, decoder) {
    let $ = decoder.function(data);
    let maybe_invalid_data = $[0];
    let errors = $[1];
    if (errors instanceof Empty) {
      return new Ok(maybe_invalid_data);
    } else {
      return new Error2(errors);
    }
  }
  function map3(decoder, transformer) {
    return new Decoder(
      (d) => {
        let $ = decoder.function(d);
        let data = $[0];
        let errors = $[1];
        return [transformer(data), errors];
      }
    );
  }

  // build/dev/javascript/gleam_stdlib/gleam_stdlib.mjs
  function identity(x) {
    return x;
  }
  function to_string(term) {
    return term.toString();
  }
  function graphemes(string5) {
    const iterator = graphemes_iterator(string5);
    if (iterator) {
      return arrayToList(Array.from(iterator).map((item) => item.segment));
    } else {
      return arrayToList(string5.match(/./gsu));
    }
  }
  var segmenter = void 0;
  function graphemes_iterator(string5) {
    if (globalThis.Intl && Intl.Segmenter) {
      segmenter || (segmenter = new Intl.Segmenter());
      return segmenter.segment(string5)[Symbol.iterator]();
    }
  }
  function split(xs, pattern) {
    return arrayToList(xs.split(pattern));
  }
  function starts_with(haystack, needle) {
    return haystack.startsWith(needle);
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
  var MIN_I32 = -(2 ** 31);
  var MAX_I32 = 2 ** 31 - 1;
  var U32 = 2 ** 32;
  var MAX_SAFE = Number.MAX_SAFE_INTEGER;
  var MIN_SAFE = Number.MIN_SAFE_INTEGER;
  function arrayToList(array3) {
    let list4 = List$Empty();
    let i = array3.length;
    while (i--) {
      list4 = List$NonEmpty(array3[i], list4);
    }
    return list4;
  }

  // build/dev/javascript/gleam_stdlib/gleam/list.mjs
  var Ascending = class extends CustomType {
  };
  var Sorting$Ascending$const = new Ascending();
  var Descending = class extends CustomType {
  };
  var Sorting$Descending$const = new Descending();
  function reverse_and_prepend(loop$prefix, loop$suffix) {
    while (true) {
      let prefix = loop$prefix;
      let suffix = loop$suffix;
      if (prefix instanceof Empty) {
        return suffix;
      } else {
        let first$1 = prefix.head;
        let rest$1 = prefix.tail;
        loop$prefix = rest$1;
        loop$suffix = prepend(first$1, suffix);
      }
    }
  }
  function reverse(list4) {
    return reverse_and_prepend(list4, List$Empty$const);
  }
  function map_loop(loop$list, loop$fun, loop$acc) {
    while (true) {
      let list4 = loop$list;
      let fun = loop$fun;
      let acc = loop$acc;
      if (list4 instanceof Empty) {
        return reverse(acc);
      } else {
        let first$1 = list4.head;
        let rest$1 = list4.tail;
        loop$list = rest$1;
        loop$fun = fun;
        loop$acc = prepend(fun(first$1), acc);
      }
    }
  }
  function map2(list4, fun) {
    return map_loop(list4, fun, List$Empty$const);
  }
  function append_loop(loop$first, loop$second) {
    while (true) {
      let first = loop$first;
      let second = loop$second;
      if (first instanceof Empty) {
        return second;
      } else {
        let first$1 = first.head;
        let rest$1 = first.tail;
        loop$first = rest$1;
        loop$second = prepend(first$1, second);
      }
    }
  }
  function append2(first, second) {
    return append_loop(reverse(first), second);
  }
  function fold2(loop$list, loop$initial, loop$fun) {
    while (true) {
      let list4 = loop$list;
      let initial = loop$initial;
      let fun = loop$fun;
      if (list4 instanceof Empty) {
        return initial;
      } else {
        let first$1 = list4.head;
        let rest$1 = list4.tail;
        loop$list = rest$1;
        loop$initial = fun(initial, first$1);
        loop$fun = fun;
      }
    }
  }
  function merge_descendings(loop$list1, loop$list2, loop$compare, loop$acc) {
    while (true) {
      let list1 = loop$list1;
      let list22 = loop$list2;
      let compare3 = loop$compare;
      let acc = loop$acc;
      if (list1 instanceof Empty) {
        let list4 = list22;
        return reverse_and_prepend(list4, acc);
      } else if (list22 instanceof Empty) {
        let list4 = list1;
        return reverse_and_prepend(list4, acc);
      } else {
        let first1 = list1.head;
        let rest1 = list1.tail;
        let first2 = list22.head;
        let rest2 = list22.tail;
        let $ = compare3(first1, first2);
        if ($ instanceof Lt) {
          loop$list1 = list1;
          loop$list2 = rest2;
          loop$compare = compare3;
          loop$acc = prepend(first2, acc);
        } else if ($ instanceof Eq) {
          loop$list1 = rest1;
          loop$list2 = list22;
          loop$compare = compare3;
          loop$acc = prepend(first1, acc);
        } else {
          loop$list1 = rest1;
          loop$list2 = list22;
          loop$compare = compare3;
          loop$acc = prepend(first1, acc);
        }
      }
    }
  }
  function merge_descending_pairs(loop$sequences, loop$compare, loop$acc) {
    while (true) {
      let sequences2 = loop$sequences;
      let compare3 = loop$compare;
      let acc = loop$acc;
      if (sequences2 instanceof Empty) {
        return reverse(acc);
      } else {
        let $ = sequences2.tail;
        if ($ instanceof Empty) {
          let sequence = sequences2.head;
          return reverse(prepend(reverse(sequence), acc));
        } else {
          let descending1 = sequences2.head;
          let descending2 = $.head;
          let rest$1 = $.tail;
          let ascending = merge_descendings(
            descending1,
            descending2,
            compare3,
            List$Empty$const
          );
          loop$sequences = rest$1;
          loop$compare = compare3;
          loop$acc = prepend(ascending, acc);
        }
      }
    }
  }
  function merge_ascendings(loop$list1, loop$list2, loop$compare, loop$acc) {
    while (true) {
      let list1 = loop$list1;
      let list22 = loop$list2;
      let compare3 = loop$compare;
      let acc = loop$acc;
      if (list1 instanceof Empty) {
        let list4 = list22;
        return reverse_and_prepend(list4, acc);
      } else if (list22 instanceof Empty) {
        let list4 = list1;
        return reverse_and_prepend(list4, acc);
      } else {
        let first1 = list1.head;
        let rest1 = list1.tail;
        let first2 = list22.head;
        let rest2 = list22.tail;
        let $ = compare3(first1, first2);
        if ($ instanceof Lt) {
          loop$list1 = rest1;
          loop$list2 = list22;
          loop$compare = compare3;
          loop$acc = prepend(first1, acc);
        } else if ($ instanceof Eq) {
          loop$list1 = list1;
          loop$list2 = rest2;
          loop$compare = compare3;
          loop$acc = prepend(first2, acc);
        } else {
          loop$list1 = list1;
          loop$list2 = rest2;
          loop$compare = compare3;
          loop$acc = prepend(first2, acc);
        }
      }
    }
  }
  function merge_ascending_pairs(loop$sequences, loop$compare, loop$acc) {
    while (true) {
      let sequences2 = loop$sequences;
      let compare3 = loop$compare;
      let acc = loop$acc;
      if (sequences2 instanceof Empty) {
        return reverse(acc);
      } else {
        let $ = sequences2.tail;
        if ($ instanceof Empty) {
          let sequence = sequences2.head;
          return reverse(prepend(reverse(sequence), acc));
        } else {
          let ascending1 = sequences2.head;
          let ascending2 = $.head;
          let rest$1 = $.tail;
          let descending = merge_ascendings(
            ascending1,
            ascending2,
            compare3,
            List$Empty$const
          );
          loop$sequences = rest$1;
          loop$compare = compare3;
          loop$acc = prepend(descending, acc);
        }
      }
    }
  }
  function merge_all(loop$sequences, loop$direction, loop$compare) {
    while (true) {
      let sequences2 = loop$sequences;
      let direction = loop$direction;
      let compare3 = loop$compare;
      if (sequences2 instanceof Empty) {
        return sequences2;
      } else if (direction instanceof Ascending) {
        if (sequences2.tail instanceof Empty) {
          let sequence = sequences2.head;
          return sequence;
        } else {
          let sequences$1 = merge_ascending_pairs(
            sequences2,
            compare3,
            List$Empty$const
          );
          loop$sequences = sequences$1;
          loop$direction = Sorting$Descending$const;
          loop$compare = compare3;
        }
      } else if (sequences2.tail instanceof Empty) {
        let sequence = sequences2.head;
        return reverse(sequence);
      } else {
        let sequences$1 = merge_descending_pairs(
          sequences2,
          compare3,
          List$Empty$const
        );
        loop$sequences = sequences$1;
        loop$direction = Sorting$Ascending$const;
        loop$compare = compare3;
      }
    }
  }
  function sequences(loop$list, loop$compare, loop$growing, loop$direction, loop$prev, loop$acc) {
    while (true) {
      let list4 = loop$list;
      let compare3 = loop$compare;
      let growing = loop$growing;
      let direction = loop$direction;
      let prev = loop$prev;
      let acc = loop$acc;
      let growing$1 = prepend(prev, growing);
      if (list4 instanceof Empty) {
        if (direction instanceof Ascending) {
          return prepend(reverse(growing$1), acc);
        } else {
          return prepend(growing$1, acc);
        }
      } else {
        let new$1 = list4.head;
        let rest$1 = list4.tail;
        let $ = compare3(prev, new$1);
        if (direction instanceof Ascending) {
          if ($ instanceof Lt) {
            loop$list = rest$1;
            loop$compare = compare3;
            loop$growing = growing$1;
            loop$direction = direction;
            loop$prev = new$1;
            loop$acc = acc;
          } else if ($ instanceof Eq) {
            loop$list = rest$1;
            loop$compare = compare3;
            loop$growing = growing$1;
            loop$direction = direction;
            loop$prev = new$1;
            loop$acc = acc;
          } else {
            let _block;
            if (direction instanceof Ascending) {
              _block = prepend(reverse(growing$1), acc);
            } else {
              _block = prepend(growing$1, acc);
            }
            let acc$1 = _block;
            if (rest$1 instanceof Empty) {
              return prepend(prepend(new$1, List$Empty$const), acc$1);
            } else {
              let next = rest$1.head;
              let rest$2 = rest$1.tail;
              let _block$1;
              let $1 = compare3(new$1, next);
              if ($1 instanceof Lt) {
                _block$1 = Sorting$Ascending$const;
              } else if ($1 instanceof Eq) {
                _block$1 = Sorting$Ascending$const;
              } else {
                _block$1 = Sorting$Descending$const;
              }
              let direction$1 = _block$1;
              loop$list = rest$2;
              loop$compare = compare3;
              loop$growing = prepend(new$1, List$Empty$const);
              loop$direction = direction$1;
              loop$prev = next;
              loop$acc = acc$1;
            }
          }
        } else if ($ instanceof Lt) {
          let _block;
          if (direction instanceof Ascending) {
            _block = prepend(reverse(growing$1), acc);
          } else {
            _block = prepend(growing$1, acc);
          }
          let acc$1 = _block;
          if (rest$1 instanceof Empty) {
            return prepend(prepend(new$1, List$Empty$const), acc$1);
          } else {
            let next = rest$1.head;
            let rest$2 = rest$1.tail;
            let _block$1;
            let $1 = compare3(new$1, next);
            if ($1 instanceof Lt) {
              _block$1 = Sorting$Ascending$const;
            } else if ($1 instanceof Eq) {
              _block$1 = Sorting$Ascending$const;
            } else {
              _block$1 = Sorting$Descending$const;
            }
            let direction$1 = _block$1;
            loop$list = rest$2;
            loop$compare = compare3;
            loop$growing = prepend(new$1, List$Empty$const);
            loop$direction = direction$1;
            loop$prev = next;
            loop$acc = acc$1;
          }
        } else if ($ instanceof Eq) {
          let _block;
          if (direction instanceof Ascending) {
            _block = prepend(reverse(growing$1), acc);
          } else {
            _block = prepend(growing$1, acc);
          }
          let acc$1 = _block;
          if (rest$1 instanceof Empty) {
            return prepend(prepend(new$1, List$Empty$const), acc$1);
          } else {
            let next = rest$1.head;
            let rest$2 = rest$1.tail;
            let _block$1;
            let $1 = compare3(new$1, next);
            if ($1 instanceof Lt) {
              _block$1 = Sorting$Ascending$const;
            } else if ($1 instanceof Eq) {
              _block$1 = Sorting$Ascending$const;
            } else {
              _block$1 = Sorting$Descending$const;
            }
            let direction$1 = _block$1;
            loop$list = rest$2;
            loop$compare = compare3;
            loop$growing = prepend(new$1, List$Empty$const);
            loop$direction = direction$1;
            loop$prev = next;
            loop$acc = acc$1;
          }
        } else {
          loop$list = rest$1;
          loop$compare = compare3;
          loop$growing = growing$1;
          loop$direction = direction;
          loop$prev = new$1;
          loop$acc = acc;
        }
      }
    }
  }
  function sort(list4, compare3) {
    if (list4 instanceof Empty) {
      return list4;
    } else {
      let $ = list4.tail;
      if ($ instanceof Empty) {
        return list4;
      } else {
        let x = list4.head;
        let y = $.head;
        let rest$1 = $.tail;
        let _block;
        let $1 = compare3(x, y);
        if ($1 instanceof Lt) {
          _block = Sorting$Ascending$const;
        } else if ($1 instanceof Eq) {
          _block = Sorting$Ascending$const;
        } else {
          _block = Sorting$Descending$const;
        }
        let direction = _block;
        let sequences$1 = sequences(
          rest$1,
          compare3,
          prepend(x, List$Empty$const),
          direction,
          y,
          List$Empty$const
        );
        return merge_all(sequences$1, Sorting$Ascending$const, compare3);
      }
    }
  }

  // build/dev/javascript/gleam_erlang/gleam/erlang/process.mjs
  var Normal = class extends CustomType {
  };
  var ExitReason$Normal$const = new Normal();
  var Killed = class extends CustomType {
  };
  var ExitReason$Killed$const = new Killed();
  var Anything = class extends CustomType {
  };
  var AnythingSelectorTag$Anything$const = new Anything();
  var Process = class extends CustomType {
  };
  var ProcessMonitorFlag$Process$const = new Process();
  var TimerNotFound = class extends CustomType {
  };
  var Cancelled$TimerNotFound$const = new TimerNotFound();
  var Kill = class extends CustomType {
  };
  var KillFlag$Kill$const = new Kill();

  // build/dev/javascript/gleam_otp/gleam/otp/system.mjs
  var Running = class extends CustomType {
  };
  var Mode$Running$const = new Running();
  var Suspended = class extends CustomType {
  };
  var Mode$Suspended$const = new Suspended();
  var NoDebug = class extends CustomType {
  };
  var DebugOption$NoDebug$const = new NoDebug();

  // build/dev/javascript/gleam_otp/gleam/otp/actor.mjs
  var InitTimeout = class extends CustomType {
  };
  var StartError$InitTimeout$const = new InitTimeout();

  // build/dev/javascript/gleam_otp/gleam/otp/supervision.mjs
  var Permanent = class extends CustomType {
  };
  var Restart$Permanent$const = new Permanent();
  var Transient = class extends CustomType {
  };
  var Restart$Transient$const = new Transient();
  var Temporary = class extends CustomType {
  };
  var Restart$Temporary$const = new Temporary();
  var Supervisor = class extends CustomType {
  };
  var ChildType$Supervisor$const = new Supervisor();

  // build/dev/javascript/gleam_otp/gleam/otp/factory_supervisor.mjs
  var SimpleOneForOne = class extends CustomType {
  };
  var Strategy$SimpleOneForOne$const = new SimpleOneForOne();

  // build/dev/javascript/gleam_stdlib/gleam/bool.mjs
  function guard(requirement, consequence, alternative) {
    if (requirement) {
      return consequence;
    } else {
      return alternative();
    }
  }

  // build/dev/javascript/gleam_stdlib/gleam/function.mjs
  function identity2(x) {
    return x;
  }

  // build/dev/javascript/gleam_json/gleam/json.mjs
  var UnexpectedEndOfInput = class extends CustomType {
  };
  var DecodeError$UnexpectedEndOfInput$const = new UnexpectedEndOfInput();

  // build/dev/javascript/houdini/houdini.ffi.mjs
  function escape(string5) {
    return string5.replaceAll(/[><&"']/g, (replaced) => {
      switch (replaced) {
        case ">":
          return "&gt;";
        case "<":
          return "&lt;";
        case "'":
          return "&#39;";
        case "&":
          return "&amp;";
        case '"':
          return "&quot;";
        default:
          return replaced;
      }
    });
  }

  // build/dev/javascript/lustre/lustre/internals/constants.mjs
  var empty_list = List$Empty$const;
  var error_nil = /* @__PURE__ */ new Error2(void 0);
  function singleton_list(item) {
    return prepend(item, empty_list);
  }

  // build/dev/javascript/lustre/lustre/vdom/vattr.ffi.mjs
  var GT = /* @__PURE__ */ Order$Gt();
  var LT = /* @__PURE__ */ Order$Lt();
  var EQ = /* @__PURE__ */ Order$Eq();
  function compare2(a, b) {
    if (a.name === b.name) {
      return EQ;
    } else if (a.name < b.name) {
      return LT;
    } else {
      return GT;
    }
  }

  // build/dev/javascript/lustre/lustre/vdom/vattr.mjs
  var Attribute = class extends CustomType {
    constructor(kind, name, value) {
      super();
      this.kind = kind;
      this.name = name;
      this.value = value;
    }
  };
  var Property = class extends CustomType {
    constructor(kind, name, value) {
      super();
      this.kind = kind;
      this.name = name;
      this.value = value;
    }
  };
  var Event2 = class extends CustomType {
    constructor(kind, name, handler, include, prevent_default, stop_propagation, debounce, throttle) {
      super();
      this.kind = kind;
      this.name = name;
      this.handler = handler;
      this.include = include;
      this.prevent_default = prevent_default;
      this.stop_propagation = stop_propagation;
      this.debounce = debounce;
      this.throttle = throttle;
    }
  };
  var Handler = class extends CustomType {
    constructor(prevent_default, stop_propagation, message) {
      super();
      this.prevent_default = prevent_default;
      this.stop_propagation = stop_propagation;
      this.message = message;
    }
  };
  var attribute_kind = 0;
  var property_kind = 1;
  var event_kind = 2;
  var never_kind = 0;
  var always_kind = 2;
  function attribute(name, value) {
    return new Attribute(attribute_kind, name, value);
  }
  function merge(loop$attributes, loop$merged) {
    while (true) {
      let attributes = loop$attributes;
      let merged = loop$merged;
      if (attributes instanceof Empty) {
        return merged;
      } else {
        let $ = attributes.head;
        if ($ instanceof Attribute) {
          let $1 = $.name;
          if ($1 === "") {
            let rest = attributes.tail;
            loop$attributes = rest;
            loop$merged = merged;
          } else if ($1 === "class") {
            let $2 = $.value;
            if ($2 === "") {
              let rest = attributes.tail;
              loop$attributes = rest;
              loop$merged = merged;
            } else {
              let $3 = attributes.tail;
              if ($3 instanceof Empty) {
                let attribute$1 = $;
                let rest = $3;
                loop$attributes = rest;
                loop$merged = prepend(attribute$1, merged);
              } else {
                let $4 = $3.head;
                if ($4 instanceof Attribute && $4.name === "class") {
                  let kind = $.kind;
                  let class1 = $2;
                  let rest = $3.tail;
                  let class2 = $4.value;
                  let value = class1 + " " + class2;
                  let attribute$1 = new Attribute(kind, "class", value);
                  loop$attributes = prepend(attribute$1, rest);
                  loop$merged = merged;
                } else {
                  let attribute$1 = $;
                  let rest = $3;
                  loop$attributes = rest;
                  loop$merged = prepend(attribute$1, merged);
                }
              }
            }
          } else if ($1 === "style") {
            let $2 = $.value;
            if ($2 === "") {
              let rest = attributes.tail;
              loop$attributes = rest;
              loop$merged = merged;
            } else {
              let $3 = attributes.tail;
              if ($3 instanceof Empty) {
                let attribute$1 = $;
                let rest = $3;
                loop$attributes = rest;
                loop$merged = prepend(attribute$1, merged);
              } else {
                let $4 = $3.head;
                if ($4 instanceof Attribute && $4.name === "style") {
                  let kind = $.kind;
                  let style1 = $2;
                  let rest = $3.tail;
                  let style2 = $4.value;
                  let value = style1 + ";" + style2;
                  let attribute$1 = new Attribute(kind, "style", value);
                  loop$attributes = prepend(attribute$1, rest);
                  loop$merged = merged;
                } else {
                  let attribute$1 = $;
                  let rest = $3;
                  loop$attributes = rest;
                  loop$merged = prepend(attribute$1, merged);
                }
              }
            }
          } else {
            let attribute$1 = $;
            let rest = attributes.tail;
            loop$attributes = rest;
            loop$merged = prepend(attribute$1, merged);
          }
        } else {
          let attribute$1 = $;
          let rest = attributes.tail;
          loop$attributes = rest;
          loop$merged = prepend(attribute$1, merged);
        }
      }
    }
  }
  function prepare(attributes) {
    if (attributes instanceof Empty) {
      return attributes;
    } else if (attributes.tail instanceof Empty) {
      return attributes;
    } else {
      let _pipe = attributes;
      let _pipe$1 = sort(_pipe, (a, b) => {
        return compare2(b, a);
      });
      return merge(_pipe$1, empty_list);
    }
  }

  // build/dev/javascript/lustre/lustre/attribute.mjs
  function attribute2(name, value) {
    return attribute(name, value);
  }
  function class$(name) {
    return attribute2("class", name);
  }
  function id(value) {
    return attribute2("id", value);
  }
  function role(name) {
    return attribute2("role", name);
  }

  // build/dev/javascript/lustre/lustre/effect.mjs
  var Effect = class extends CustomType {
    constructor(synchronous, before_paint2, after_paint) {
      super();
      this.synchronous = synchronous;
      this.before_paint = before_paint2;
      this.after_paint = after_paint;
    }
  };
  var empty = /* @__PURE__ */ new Effect(
    empty_list,
    empty_list,
    empty_list
  );
  function none() {
    return empty;
  }
  function from2(effect) {
    let task = (actions) => {
      let dispatch2 = actions.dispatch;
      return effect(dispatch2);
    };
    return new Effect(
      singleton_list(task),
      empty.before_paint,
      empty.after_paint
    );
  }

  // build/dev/javascript/lustre/lustre/internals/mutable_map.ffi.mjs
  function empty2() {
    return null;
  }
  function get2(map6, key) {
    return map6?.get(key);
  }
  function get_or_compute(map6, key, compute) {
    return map6?.get(key) ?? compute();
  }
  function has_key(map6, key) {
    return map6 && map6.has(key);
  }
  function insert2(map6, key, value) {
    map6 ?? (map6 = /* @__PURE__ */ new Map());
    map6.set(key, value);
    return map6;
  }
  function remove(map6, key) {
    map6?.delete(key);
    return map6;
  }

  // build/dev/javascript/lustre/lustre/internals/ref.ffi.mjs
  function sameValueZero(x, y) {
    if (typeof x === "number" && typeof y === "number") {
      return x === y || x !== x && y !== y;
    }
    return x === y;
  }

  // build/dev/javascript/lustre/lustre/internals/ref.mjs
  function equal_lists(loop$xs, loop$ys) {
    while (true) {
      let xs = loop$xs;
      let ys = loop$ys;
      if (xs instanceof Empty) {
        if (ys instanceof Empty) {
          return true;
        } else {
          return false;
        }
      } else if (ys instanceof Empty) {
        return false;
      } else {
        let x = xs.head;
        let xs$1 = xs.tail;
        let y = ys.head;
        let ys$1 = ys.tail;
        let $ = sameValueZero(x, y);
        if ($) {
          loop$xs = xs$1;
          loop$ys = ys$1;
        } else {
          return $;
        }
      }
    }
  }

  // build/dev/javascript/lustre/lustre/vdom/vnode.mjs
  var Fragment = class extends CustomType {
    constructor(kind, key, children, keyed_children) {
      super();
      this.kind = kind;
      this.key = key;
      this.children = children;
      this.keyed_children = keyed_children;
    }
  };
  var Element = class extends CustomType {
    constructor(kind, key, namespace, tag, attributes, children, keyed_children, self_closing, void$) {
      super();
      this.kind = kind;
      this.key = key;
      this.namespace = namespace;
      this.tag = tag;
      this.attributes = attributes;
      this.children = children;
      this.keyed_children = keyed_children;
      this.self_closing = self_closing;
      this.void = void$;
    }
  };
  var Text = class extends CustomType {
    constructor(kind, key, content) {
      super();
      this.kind = kind;
      this.key = key;
      this.content = content;
    }
  };
  var UnsafeInnerHtml = class extends CustomType {
    constructor(kind, key, namespace, tag, attributes, inner_html) {
      super();
      this.kind = kind;
      this.key = key;
      this.namespace = namespace;
      this.tag = tag;
      this.attributes = attributes;
      this.inner_html = inner_html;
    }
  };
  var Map2 = class extends CustomType {
    constructor(kind, key, mapper, child2) {
      super();
      this.kind = kind;
      this.key = key;
      this.mapper = mapper;
      this.child = child2;
    }
  };
  var Memo = class extends CustomType {
    constructor(kind, key, dependencies, view2) {
      super();
      this.kind = kind;
      this.key = key;
      this.dependencies = dependencies;
      this.view = view2;
    }
  };
  var fragment_kind = 0;
  var element_kind = 1;
  var text_kind = 2;
  var unsafe_inner_html_kind = 3;
  var map_kind = 4;
  var memo_kind = 5;
  function fragment(key, children, keyed_children) {
    return new Fragment(fragment_kind, key, children, keyed_children);
  }
  function element(key, namespace, tag, attributes, children, keyed_children, self_closing, void$) {
    return new Element(
      element_kind,
      key,
      namespace,
      tag,
      prepare(attributes),
      children,
      keyed_children,
      self_closing,
      void$
    );
  }
  function is_void_html_element(tag, namespace) {
    if (namespace === "") {
      if (tag === "area") {
        return true;
      } else if (tag === "base") {
        return true;
      } else if (tag === "br") {
        return true;
      } else if (tag === "col") {
        return true;
      } else if (tag === "embed") {
        return true;
      } else if (tag === "hr") {
        return true;
      } else if (tag === "img") {
        return true;
      } else if (tag === "input") {
        return true;
      } else if (tag === "link") {
        return true;
      } else if (tag === "meta") {
        return true;
      } else if (tag === "param") {
        return true;
      } else if (tag === "source") {
        return true;
      } else if (tag === "track") {
        return true;
      } else if (tag === "wbr") {
        return true;
      } else {
        return false;
      }
    } else {
      return false;
    }
  }
  function text(key, content) {
    return new Text(text_kind, key, content);
  }
  function map4(element4, mapper) {
    if (element4 instanceof Map2) {
      let child_mapper = element4.mapper;
      return new Map2(
        map_kind,
        element4.key,
        (handler) => {
          return identity2(mapper)(child_mapper(handler));
        },
        identity2(element4.child)
      );
    } else {
      return new Map2(map_kind, element4.key, identity2(mapper), identity2(element4));
    }
  }
  function memo(key, dependencies, view2) {
    return new Memo(memo_kind, key, dependencies, view2);
  }
  function to_keyed(key, node) {
    if (node instanceof Fragment) {
      return new Fragment(node.kind, key, node.children, node.keyed_children);
    } else if (node instanceof Element) {
      return new Element(
        node.kind,
        key,
        node.namespace,
        node.tag,
        node.attributes,
        node.children,
        node.keyed_children,
        node.self_closing,
        node.void
      );
    } else if (node instanceof Text) {
      return new Text(node.kind, key, node.content);
    } else if (node instanceof UnsafeInnerHtml) {
      return new UnsafeInnerHtml(
        node.kind,
        key,
        node.namespace,
        node.tag,
        node.attributes,
        node.inner_html
      );
    } else if (node instanceof Map2) {
      let child2 = node.child;
      return new Map2(node.kind, key, node.mapper, to_keyed(key, child2));
    } else {
      let view2 = node.view;
      return new Memo(
        node.kind,
        key,
        node.dependencies,
        () => {
          return to_keyed(key, view2());
        }
      );
    }
  }

  // build/dev/javascript/lustre/lustre/element.mjs
  var Html = class extends CustomType {
  };
  var DocumentType$Html$const = new Html();
  var HeadOnly = class extends CustomType {
  };
  var DocumentType$HeadOnly$const = new HeadOnly();
  var BodyOnly = class extends CustomType {
  };
  var DocumentType$BodyOnly$const = new BodyOnly();
  var HeadAndBody = class extends CustomType {
  };
  var DocumentType$HeadAndBody$const = new HeadAndBody();
  var Other = class extends CustomType {
  };
  var DocumentType$Other$const = new Other();
  function element2(tag, attributes, children) {
    return element(
      "",
      "",
      tag,
      attributes,
      children,
      empty2(),
      false,
      is_void_html_element(tag, "")
    );
  }
  function text2(content) {
    return text("", content);
  }
  function none2() {
    return text("", "");
  }
  function fragment2(children) {
    return fragment("", children, empty2());
  }
  function memo2(dependencies, view2) {
    return memo("", dependencies, view2);
  }
  function ref(value) {
    return identity2(value);
  }
  function map5(element4, f) {
    return map4(element4, f);
  }

  // build/dev/javascript/lustre/lustre/element/html.mjs
  function div(attrs, children) {
    return element2("div", attrs, children);
  }
  function li(attrs, children) {
    return element2("li", attrs, children);
  }
  function p(attrs, children) {
    return element2("p", attrs, children);
  }
  function ul(attrs, children) {
    return element2("ul", attrs, children);
  }
  function span(attrs, children) {
    return element2("span", attrs, children);
  }
  function strong(attrs, children) {
    return element2("strong", attrs, children);
  }

  // build/dev/javascript/lustre/lustre/vdom/patch.mjs
  var Patch = class extends CustomType {
    constructor(index2, path, removed, changes, children) {
      super();
      this.index = index2;
      this.path = path;
      this.removed = removed;
      this.changes = changes;
      this.children = children;
    }
  };
  var ReplaceText = class extends CustomType {
    constructor(kind, content) {
      super();
      this.kind = kind;
      this.content = content;
    }
  };
  var ReplaceInnerHtml = class extends CustomType {
    constructor(kind, inner_html) {
      super();
      this.kind = kind;
      this.inner_html = inner_html;
    }
  };
  var Update = class extends CustomType {
    constructor(kind, added, removed) {
      super();
      this.kind = kind;
      this.added = added;
      this.removed = removed;
    }
  };
  var Move = class extends CustomType {
    constructor(kind, key, before) {
      super();
      this.kind = kind;
      this.key = key;
      this.before = before;
    }
  };
  var Replace = class extends CustomType {
    constructor(kind, index2, with$) {
      super();
      this.kind = kind;
      this.index = index2;
      this.with = with$;
    }
  };
  var Remove = class extends CustomType {
    constructor(kind, index2) {
      super();
      this.kind = kind;
      this.index = index2;
    }
  };
  var Insert = class extends CustomType {
    constructor(kind, children, before) {
      super();
      this.kind = kind;
      this.children = children;
      this.before = before;
    }
  };
  var replace_text_kind = 0;
  var replace_inner_html_kind = 1;
  var update_kind = 2;
  var move_kind = 3;
  var remove_kind = 4;
  var replace_kind = 5;
  var insert_kind = 6;
  function new$3(index2, removed, changes, children) {
    return new Patch(index2, empty_list, removed, changes, children);
  }
  function replace_text(content) {
    return new ReplaceText(replace_text_kind, content);
  }
  function replace_inner_html(inner_html) {
    return new ReplaceInnerHtml(replace_inner_html_kind, inner_html);
  }
  function update(added, removed) {
    return new Update(update_kind, added, removed);
  }
  function move(key, before) {
    return new Move(move_kind, key, before);
  }
  function remove2(index2) {
    return new Remove(remove_kind, index2);
  }
  function replace2(index2, with$) {
    return new Replace(replace_kind, index2, with$);
  }
  function insert3(children, before) {
    return new Insert(insert_kind, children, before);
  }
  function add_parent(child2, index2) {
    return new Patch(
      index2,
      prepend(child2.index, child2.path),
      child2.removed,
      child2.changes,
      child2.children
    );
  }

  // build/dev/javascript/lustre/lustre/vdom/path.mjs
  var Root = class extends CustomType {
  };
  var Path$Root$const = new Root();
  var Key = class extends CustomType {
    constructor(key, parent) {
      super();
      this.key = key;
      this.parent = parent;
    }
  };
  var Index = class extends CustomType {
    constructor(index2, parent) {
      super();
      this.index = index2;
      this.parent = parent;
    }
  };
  var Subtree = class extends CustomType {
    constructor(parent) {
      super();
      this.parent = parent;
    }
  };
  var separator_subtree = "\r";
  var separator_element = "	";
  var separator_event = "\n";
  var root = Path$Root$const;
  function finish_to_string(acc) {
    if (acc instanceof Empty) {
      return "";
    } else {
      let segments = acc.tail;
      return concat2(segments);
    }
  }
  function do_to_string(loop$full, loop$path, loop$acc) {
    while (true) {
      let full = loop$full;
      let path = loop$path;
      let acc = loop$acc;
      if (path instanceof Root) {
        return finish_to_string(acc);
      } else if (path instanceof Key) {
        let key = path.key;
        let parent = path.parent;
        loop$full = full;
        loop$path = parent;
        loop$acc = prepend(separator_element, prepend(key, acc));
      } else if (path instanceof Index) {
        let index2 = path.index;
        let parent = path.parent;
        let acc$1 = prepend(
          separator_element,
          prepend(to_string(index2), acc)
        );
        loop$full = full;
        loop$path = parent;
        loop$acc = acc$1;
      } else if (!full) {
        return finish_to_string(acc);
      } else {
        let parent = path.parent;
        if (acc instanceof Empty) {
          loop$full = full;
          loop$path = parent;
          loop$acc = acc;
        } else {
          let acc$1 = acc.tail;
          loop$full = full;
          loop$path = parent;
          loop$acc = prepend(separator_subtree, acc$1);
        }
      }
    }
  }
  function to_string3(path) {
    return do_to_string(true, path, empty_list);
  }
  function do_matches(loop$path, loop$candidates) {
    while (true) {
      let path = loop$path;
      let candidates = loop$candidates;
      if (candidates instanceof Empty) {
        return false;
      } else {
        let candidate = candidates.head;
        let rest = candidates.tail;
        let $ = starts_with(path, candidate);
        if ($) {
          return $;
        } else {
          loop$path = path;
          loop$candidates = rest;
        }
      }
    }
  }
  function matches(path, candidates) {
    if (candidates instanceof Empty) {
      return false;
    } else {
      return do_matches(to_string3(path), candidates);
    }
  }
  function split_subtree_path(path) {
    return split2(path, separator_subtree);
  }
  function add2(parent, index2, key) {
    if (key === "") {
      return new Index(index2, parent);
    } else {
      return new Key(key, parent);
    }
  }
  function subtree(path) {
    return new Subtree(path);
  }
  function event(path, event2) {
    return do_to_string(
      false,
      path,
      prepend(separator_event, prepend(event2, empty_list))
    );
  }
  function child(path) {
    return do_to_string(false, path, empty_list);
  }

  // build/dev/javascript/lustre/lustre/vdom/cache.mjs
  var Cache = class extends CustomType {
    constructor(events2, vdoms, old_vdoms, dispatched_paths, next_dispatched_paths) {
      super();
      this.events = events2;
      this.vdoms = vdoms;
      this.old_vdoms = old_vdoms;
      this.dispatched_paths = dispatched_paths;
      this.next_dispatched_paths = next_dispatched_paths;
    }
  };
  var Events = class extends CustomType {
    constructor(handlers, children) {
      super();
      this.handlers = handlers;
      this.children = children;
    }
  };
  var Child = class extends CustomType {
    constructor(mapper, events2) {
      super();
      this.mapper = mapper;
      this.events = events2;
    }
  };
  var AddedChildren = class extends CustomType {
    constructor(handlers, children, vdoms) {
      super();
      this.handlers = handlers;
      this.children = children;
      this.vdoms = vdoms;
    }
  };
  var DecodedEvent = class extends CustomType {
    constructor(path, handler) {
      super();
      this.path = path;
      this.handler = handler;
    }
  };
  var DispatchedEvent = class extends CustomType {
    constructor(path) {
      super();
      this.path = path;
    }
  };
  function compose_mapper(mapper, child_mapper) {
    return (message) => {
      return mapper(child_mapper(message));
    };
  }
  function new_events() {
    return new Events(empty2(), empty2());
  }
  function new$4() {
    return new Cache(
      new_events(),
      empty2(),
      empty2(),
      empty_list,
      empty_list
    );
  }
  function do_add_event(handlers, path, name, handler) {
    return insert2(handlers, event(path, name), handler);
  }
  function add_attributes(handlers, path, attributes) {
    return fold2(
      attributes,
      handlers,
      (events2, attribute3) => {
        if (attribute3 instanceof Event2) {
          let name = attribute3.name;
          let handler = attribute3.handler;
          return do_add_event(events2, path, name, handler);
        } else {
          return events2;
        }
      }
    );
  }
  function do_add_children(loop$handlers, loop$children, loop$vdoms, loop$parent, loop$child_index, loop$nodes) {
    while (true) {
      let handlers = loop$handlers;
      let children = loop$children;
      let vdoms = loop$vdoms;
      let parent = loop$parent;
      let child_index = loop$child_index;
      let nodes = loop$nodes;
      let next = child_index + 1;
      if (nodes instanceof Empty) {
        return new AddedChildren(handlers, children, vdoms);
      } else {
        let $ = nodes.head;
        if ($ instanceof Fragment) {
          let rest = nodes.tail;
          let key = $.key;
          let nodes$1 = $.children;
          let path = add2(parent, child_index, key);
          let $1 = do_add_children(handlers, children, vdoms, path, 0, nodes$1);
          let handlers$1 = $1.handlers;
          let children$1 = $1.children;
          let vdoms$1 = $1.vdoms;
          loop$handlers = handlers$1;
          loop$children = children$1;
          loop$vdoms = vdoms$1;
          loop$parent = parent;
          loop$child_index = next;
          loop$nodes = rest;
        } else if ($ instanceof Element) {
          let rest = nodes.tail;
          let key = $.key;
          let attributes = $.attributes;
          let nodes$1 = $.children;
          let path = add2(parent, child_index, key);
          let handlers$1 = add_attributes(handlers, path, attributes);
          let $1 = do_add_children(handlers$1, children, vdoms, path, 0, nodes$1);
          let handlers$2 = $1.handlers;
          let children$1 = $1.children;
          let vdoms$1 = $1.vdoms;
          loop$handlers = handlers$2;
          loop$children = children$1;
          loop$vdoms = vdoms$1;
          loop$parent = parent;
          loop$child_index = next;
          loop$nodes = rest;
        } else if ($ instanceof Text) {
          let rest = nodes.tail;
          loop$handlers = handlers;
          loop$children = children;
          loop$vdoms = vdoms;
          loop$parent = parent;
          loop$child_index = next;
          loop$nodes = rest;
        } else if ($ instanceof UnsafeInnerHtml) {
          let rest = nodes.tail;
          let key = $.key;
          let attributes = $.attributes;
          let path = add2(parent, child_index, key);
          let handlers$1 = add_attributes(handlers, path, attributes);
          loop$handlers = handlers$1;
          loop$children = children;
          loop$vdoms = vdoms;
          loop$parent = parent;
          loop$child_index = next;
          loop$nodes = rest;
        } else if ($ instanceof Map2) {
          let rest = nodes.tail;
          let key = $.key;
          let mapper = $.mapper;
          let child2 = $.child;
          let path = add2(parent, child_index, key);
          let added = do_add_children(
            empty2(),
            empty2(),
            vdoms,
            subtree(path),
            0,
            singleton_list(child2)
          );
          let vdoms$1 = added.vdoms;
          let child_events = new Events(added.handlers, added.children);
          let child$1 = new Child(mapper, child_events);
          let children$1 = insert2(
            children,
            child(path),
            child$1
          );
          loop$handlers = handlers;
          loop$children = children$1;
          loop$vdoms = vdoms$1;
          loop$parent = parent;
          loop$child_index = next;
          loop$nodes = rest;
        } else {
          let rest = nodes.tail;
          let view2 = $.view;
          let child_node = view2();
          let vdoms$1 = insert2(vdoms, view2, child_node);
          let next$1 = child_index;
          let rest$1 = prepend(child_node, rest);
          loop$handlers = handlers;
          loop$children = children;
          loop$vdoms = vdoms$1;
          loop$parent = parent;
          loop$child_index = next$1;
          loop$nodes = rest$1;
        }
      }
    }
  }
  function add_children(cache, events2, path, child_index, nodes) {
    let vdoms = cache.vdoms;
    let handlers = events2.handlers;
    let children = events2.children;
    let $ = do_add_children(handlers, children, vdoms, path, child_index, nodes);
    let handlers$1 = $.handlers;
    let children$1 = $.children;
    let vdoms$1 = $.vdoms;
    return [
      new Cache(
        cache.events,
        vdoms$1,
        cache.old_vdoms,
        cache.dispatched_paths,
        cache.next_dispatched_paths
      ),
      new Events(handlers$1, children$1)
    ];
  }
  function add_child(cache, events2, parent, index2, child2) {
    let children = singleton_list(child2);
    return add_children(cache, events2, parent, index2, children);
  }
  function tick(cache) {
    return new Cache(
      cache.events,
      empty2(),
      cache.vdoms,
      cache.next_dispatched_paths,
      empty_list
    );
  }
  function events(cache) {
    return cache.events;
  }
  function update_events(cache, events2) {
    return new Cache(
      events2,
      cache.vdoms,
      cache.old_vdoms,
      cache.dispatched_paths,
      cache.next_dispatched_paths
    );
  }
  function memos(cache) {
    return cache.vdoms;
  }
  function get_old_memo(cache, old, new$5) {
    return get_or_compute(cache.old_vdoms, old, new$5);
  }
  function keep_memo(cache, old, new$5) {
    let node = get_or_compute(cache.old_vdoms, old, new$5);
    let vdoms = insert2(cache.vdoms, new$5, node);
    return new Cache(
      cache.events,
      vdoms,
      cache.old_vdoms,
      cache.dispatched_paths,
      cache.next_dispatched_paths
    );
  }
  function add_memo(cache, new$5, node) {
    let vdoms = insert2(cache.vdoms, new$5, node);
    return new Cache(
      cache.events,
      vdoms,
      cache.old_vdoms,
      cache.dispatched_paths,
      cache.next_dispatched_paths
    );
  }
  function get_subtree(events2, path, old_mapper) {
    let child2 = get_or_compute(
      events2.children,
      path,
      () => {
        return new Child(old_mapper, new_events());
      }
    );
    return child2.events;
  }
  function update_subtree(parent, path, mapper, events2) {
    let new_child = new Child(mapper, events2);
    let children = insert2(parent.children, path, new_child);
    return new Events(parent.handlers, children);
  }
  function add_event(events2, path, name, handler) {
    let handlers = do_add_event(events2.handlers, path, name, handler);
    return new Events(handlers, events2.children);
  }
  function do_remove_event(handlers, path, name) {
    return remove(handlers, event(path, name));
  }
  function remove_event(events2, path, name) {
    let handlers = do_remove_event(events2.handlers, path, name);
    return new Events(handlers, events2.children);
  }
  function remove_attributes(handlers, path, attributes) {
    return fold2(
      attributes,
      handlers,
      (events2, attribute3) => {
        if (attribute3 instanceof Event2) {
          let name = attribute3.name;
          return do_remove_event(events2, path, name);
        } else {
          return events2;
        }
      }
    );
  }
  function do_remove_children(loop$handlers, loop$children, loop$vdoms, loop$parent, loop$index, loop$nodes) {
    while (true) {
      let handlers = loop$handlers;
      let children = loop$children;
      let vdoms = loop$vdoms;
      let parent = loop$parent;
      let index2 = loop$index;
      let nodes = loop$nodes;
      let next = index2 + 1;
      if (nodes instanceof Empty) {
        return new Events(handlers, children);
      } else {
        let $ = nodes.head;
        if ($ instanceof Fragment) {
          let rest = nodes.tail;
          let key = $.key;
          let nodes$1 = $.children;
          let path = add2(parent, index2, key);
          let $1 = do_remove_children(handlers, children, vdoms, path, 0, nodes$1);
          let handlers$1 = $1.handlers;
          let children$1 = $1.children;
          loop$handlers = handlers$1;
          loop$children = children$1;
          loop$vdoms = vdoms;
          loop$parent = parent;
          loop$index = next;
          loop$nodes = rest;
        } else if ($ instanceof Element) {
          let rest = nodes.tail;
          let key = $.key;
          let attributes = $.attributes;
          let nodes$1 = $.children;
          let path = add2(parent, index2, key);
          let handlers$1 = remove_attributes(handlers, path, attributes);
          let $1 = do_remove_children(
            handlers$1,
            children,
            vdoms,
            path,
            0,
            nodes$1
          );
          let handlers$2 = $1.handlers;
          let children$1 = $1.children;
          loop$handlers = handlers$2;
          loop$children = children$1;
          loop$vdoms = vdoms;
          loop$parent = parent;
          loop$index = next;
          loop$nodes = rest;
        } else if ($ instanceof Text) {
          let rest = nodes.tail;
          loop$handlers = handlers;
          loop$children = children;
          loop$vdoms = vdoms;
          loop$parent = parent;
          loop$index = next;
          loop$nodes = rest;
        } else if ($ instanceof UnsafeInnerHtml) {
          let rest = nodes.tail;
          let key = $.key;
          let attributes = $.attributes;
          let path = add2(parent, index2, key);
          let handlers$1 = remove_attributes(handlers, path, attributes);
          loop$handlers = handlers$1;
          loop$children = children;
          loop$vdoms = vdoms;
          loop$parent = parent;
          loop$index = next;
          loop$nodes = rest;
        } else if ($ instanceof Map2) {
          let rest = nodes.tail;
          let key = $.key;
          let path = add2(parent, index2, key);
          let children$1 = remove(children, child(path));
          loop$handlers = handlers;
          loop$children = children$1;
          loop$vdoms = vdoms;
          loop$parent = parent;
          loop$index = next;
          loop$nodes = rest;
        } else {
          let rest = nodes.tail;
          let view2 = $.view;
          let $1 = has_key(vdoms, view2);
          if ($1) {
            let child2 = get2(vdoms, view2);
            let nodes$1 = prepend(child2, rest);
            loop$handlers = handlers;
            loop$children = children;
            loop$vdoms = vdoms;
            loop$parent = parent;
            loop$index = index2;
            loop$nodes = nodes$1;
          } else {
            loop$handlers = handlers;
            loop$children = children;
            loop$vdoms = vdoms;
            loop$parent = parent;
            loop$index = next;
            loop$nodes = rest;
          }
        }
      }
    }
  }
  function remove_child(cache, events2, parent, child_index, child2) {
    return do_remove_children(
      events2.handlers,
      events2.children,
      cache.old_vdoms,
      parent,
      child_index,
      singleton_list(child2)
    );
  }
  function replace_child(cache, events2, parent, child_index, prev, next) {
    let events$1 = remove_child(cache, events2, parent, child_index, prev);
    return add_child(cache, events$1, parent, child_index, next);
  }
  function get_handler(loop$events, loop$path, loop$mapper) {
    while (true) {
      let events2 = loop$events;
      let path = loop$path;
      let mapper = loop$mapper;
      if (path instanceof Empty) {
        return error_nil;
      } else {
        let $ = path.tail;
        if ($ instanceof Empty) {
          let key = path.head;
          let $1 = has_key(events2.handlers, key);
          if ($1) {
            let handler = get2(events2.handlers, key);
            return new Ok(
              map3(
                handler,
                (handler2) => {
                  return new Handler(
                    handler2.prevent_default,
                    handler2.stop_propagation,
                    identity2(mapper)(handler2.message)
                  );
                }
              )
            );
          } else {
            return error_nil;
          }
        } else {
          let key = path.head;
          let path$1 = $;
          let $1 = has_key(events2.children, key);
          if ($1) {
            let child2 = get2(events2.children, key);
            let mapper$1 = compose_mapper(mapper, child2.mapper);
            loop$events = child2.events;
            loop$path = path$1;
            loop$mapper = mapper$1;
          } else {
            return error_nil;
          }
        }
      }
    }
  }
  function decode2(cache, path, name, event2) {
    let parts = split_subtree_path(path + separator_event + name);
    let $ = get_handler(cache.events, parts, identity2);
    if ($ instanceof Ok) {
      let handler = $[0];
      let $1 = run(event2, handler);
      if ($1 instanceof Ok) {
        let handler$1 = $1[0];
        return new DecodedEvent(path, handler$1);
      } else {
        return new DispatchedEvent(path);
      }
    } else {
      return new DispatchedEvent(path);
    }
  }
  function dispatch(cache, event2) {
    let next_dispatched_paths = prepend(
      event2.path,
      cache.next_dispatched_paths
    );
    let cache$1 = new Cache(
      cache.events,
      cache.vdoms,
      cache.old_vdoms,
      cache.dispatched_paths,
      next_dispatched_paths
    );
    if (event2 instanceof DecodedEvent) {
      let handler = event2.handler;
      return [cache$1, new Ok(handler)];
    } else {
      return [cache$1, error_nil];
    }
  }
  function has_dispatched_events(cache, path) {
    return matches(path, cache.dispatched_paths);
  }

  // build/dev/javascript/lustre/lustre/runtime/server/runtime.mjs
  var EffectDispatchedMessage = class extends CustomType {
    constructor(message) {
      super();
      this.message = message;
    }
  };
  var Message$isEffectDispatchedMessage = (value) => value instanceof EffectDispatchedMessage;
  var EffectEmitEvent = class extends CustomType {
    constructor(name, data) {
      super();
      this.name = name;
      this.data = data;
    }
  };
  var Message$isEffectEmitEvent = (value) => value instanceof EffectEmitEvent;
  var SystemRequestedShutdown = class extends CustomType {
  };
  var Message$SystemRequestedShutdown$const = new SystemRequestedShutdown();
  var Message$isSystemRequestedShutdown = (value) => value instanceof SystemRequestedShutdown;

  // build/dev/javascript/lustre/lustre/runtime/app.mjs
  var App = class extends CustomType {
    constructor(name, init2, update3, view2, config) {
      super();
      this.name = name;
      this.init = init2;
      this.update = update3;
      this.view = view2;
      this.config = config;
    }
  };
  var Config2 = class extends CustomType {
    constructor(open_shadow_root, adopt_styles, delegates_focus, attributes, properties, contexts, is_form_associated, on_form_autofill, on_form_reset, on_form_restore, on_form_disabled, on_connect, on_adopt, on_disconnect) {
      super();
      this.open_shadow_root = open_shadow_root;
      this.adopt_styles = adopt_styles;
      this.delegates_focus = delegates_focus;
      this.attributes = attributes;
      this.properties = properties;
      this.contexts = contexts;
      this.is_form_associated = is_form_associated;
      this.on_form_autofill = on_form_autofill;
      this.on_form_reset = on_form_reset;
      this.on_form_restore = on_form_restore;
      this.on_form_disabled = on_form_disabled;
      this.on_connect = on_connect;
      this.on_adopt = on_adopt;
      this.on_disconnect = on_disconnect;
    }
  };
  var default_config = /* @__PURE__ */ new Config2(
    true,
    true,
    false,
    empty_list,
    empty_list,
    empty_list,
    false,
    Option$None$const,
    Option$None$const,
    Option$None$const,
    Option$None$const,
    Option$None$const,
    Option$None$const,
    Option$None$const
  );

  // build/dev/javascript/lustre/lustre/internals/equals.ffi.mjs
  var isEqual2 = (a, b) => {
    if (a === b) {
      return true;
    }
    if (a == null || b == null) {
      return false;
    }
    const type = typeof a;
    if (type !== typeof b) {
      return false;
    }
    if (type !== "object") {
      return false;
    }
    const ctor = a.constructor;
    if (ctor !== b.constructor) {
      return false;
    }
    if (Array.isArray(a)) {
      return areArraysEqual(a, b);
    }
    return areObjectsEqual(a, b);
  };
  var areArraysEqual = (a, b) => {
    let index2 = a.length;
    if (index2 !== b.length) {
      return false;
    }
    while (index2--) {
      if (!isEqual2(a[index2], b[index2])) {
        return false;
      }
    }
    return true;
  };
  var areObjectsEqual = (a, b) => {
    const properties = Object.keys(a);
    let index2 = properties.length;
    if (Object.keys(b).length !== index2) {
      return false;
    }
    while (index2--) {
      const property3 = properties[index2];
      if (!Object.hasOwn(b, property3)) {
        return false;
      }
      if (!isEqual2(a[property3], b[property3])) {
        return false;
      }
    }
    return true;
  };

  // build/dev/javascript/lustre/lustre/vdom/diff.mjs
  var Diff = class extends CustomType {
    constructor(patch, cache) {
      super();
      this.patch = patch;
      this.cache = cache;
    }
  };
  var PartialDiff = class extends CustomType {
    constructor(patch, cache, events2) {
      super();
      this.patch = patch;
      this.cache = cache;
      this.events = events2;
    }
  };
  var AttributeChange = class extends CustomType {
    constructor(added, removed, events2) {
      super();
      this.added = added;
      this.removed = removed;
      this.events = events2;
    }
  };
  function diff_attributes(loop$controlled, loop$path, loop$events, loop$old, loop$new, loop$added, loop$removed) {
    while (true) {
      let controlled = loop$controlled;
      let path = loop$path;
      let events2 = loop$events;
      let old = loop$old;
      let new$5 = loop$new;
      let added = loop$added;
      let removed = loop$removed;
      if (old instanceof Empty) {
        if (new$5 instanceof Empty) {
          return new AttributeChange(added, removed, events2);
        } else {
          let $ = new$5.head;
          if ($ instanceof Event2) {
            let next = $;
            let new$1 = new$5.tail;
            let name = $.name;
            let handler = $.handler;
            let events$1 = add_event(events2, path, name, handler);
            let added$1 = prepend(next, added);
            loop$controlled = controlled;
            loop$path = path;
            loop$events = events$1;
            loop$old = old;
            loop$new = new$1;
            loop$added = added$1;
            loop$removed = removed;
          } else {
            let next = $;
            let new$1 = new$5.tail;
            let added$1 = prepend(next, added);
            loop$controlled = controlled;
            loop$path = path;
            loop$events = events2;
            loop$old = old;
            loop$new = new$1;
            loop$added = added$1;
            loop$removed = removed;
          }
        }
      } else if (new$5 instanceof Empty) {
        let $ = old.head;
        if ($ instanceof Event2) {
          let prev = $;
          let old$1 = old.tail;
          let name = $.name;
          let events$1 = remove_event(events2, path, name);
          let removed$1 = prepend(prev, removed);
          loop$controlled = controlled;
          loop$path = path;
          loop$events = events$1;
          loop$old = old$1;
          loop$new = new$5;
          loop$added = added;
          loop$removed = removed$1;
        } else {
          let prev = $;
          let old$1 = old.tail;
          let removed$1 = prepend(prev, removed);
          loop$controlled = controlled;
          loop$path = path;
          loop$events = events2;
          loop$old = old$1;
          loop$new = new$5;
          loop$added = added;
          loop$removed = removed$1;
        }
      } else {
        let prev = old.head;
        let remaining_old = old.tail;
        let next = new$5.head;
        let remaining_new = new$5.tail;
        let $ = compare2(prev, next);
        if ($ instanceof Lt) {
          if (prev instanceof Event2) {
            let name = prev.name;
            loop$controlled = controlled;
            loop$path = path;
            loop$events = remove_event(events2, path, name);
            loop$old = remaining_old;
            loop$new = new$5;
            loop$added = added;
            loop$removed = prepend(prev, removed);
          } else {
            loop$controlled = controlled;
            loop$path = path;
            loop$events = events2;
            loop$old = remaining_old;
            loop$new = new$5;
            loop$added = added;
            loop$removed = prepend(prev, removed);
          }
        } else if ($ instanceof Eq) {
          if (prev instanceof Attribute) {
            if (next instanceof Attribute) {
              let _block;
              let $1 = next.name;
              if ($1 === "value") {
                _block = controlled || prev.value !== next.value;
              } else if ($1 === "checked") {
                _block = controlled || prev.value !== next.value;
              } else if ($1 === "selected") {
                _block = controlled || prev.value !== next.value;
              } else {
                _block = prev.value !== next.value;
              }
              let has_changes = _block;
              let _block$1;
              if (has_changes) {
                _block$1 = prepend(next, added);
              } else {
                _block$1 = added;
              }
              let added$1 = _block$1;
              loop$controlled = controlled;
              loop$path = path;
              loop$events = events2;
              loop$old = remaining_old;
              loop$new = remaining_new;
              loop$added = added$1;
              loop$removed = removed;
            } else if (next instanceof Event2) {
              let name = next.name;
              let handler = next.handler;
              loop$controlled = controlled;
              loop$path = path;
              loop$events = add_event(events2, path, name, handler);
              loop$old = remaining_old;
              loop$new = remaining_new;
              loop$added = prepend(next, added);
              loop$removed = prepend(prev, removed);
            } else {
              loop$controlled = controlled;
              loop$path = path;
              loop$events = events2;
              loop$old = remaining_old;
              loop$new = remaining_new;
              loop$added = prepend(next, added);
              loop$removed = prepend(prev, removed);
            }
          } else if (prev instanceof Property) {
            if (next instanceof Property) {
              let _block;
              let $1 = next.name;
              if ($1 === "scrollLeft") {
                _block = true;
              } else if ($1 === "scrollRight") {
                _block = true;
              } else if ($1 === "value") {
                _block = controlled || !isEqual2(
                  prev.value,
                  next.value
                );
              } else if ($1 === "checked") {
                _block = controlled || !isEqual2(
                  prev.value,
                  next.value
                );
              } else if ($1 === "selected") {
                _block = controlled || !isEqual2(
                  prev.value,
                  next.value
                );
              } else {
                _block = !isEqual2(prev.value, next.value);
              }
              let has_changes = _block;
              let _block$1;
              if (has_changes) {
                _block$1 = prepend(next, added);
              } else {
                _block$1 = added;
              }
              let added$1 = _block$1;
              loop$controlled = controlled;
              loop$path = path;
              loop$events = events2;
              loop$old = remaining_old;
              loop$new = remaining_new;
              loop$added = added$1;
              loop$removed = removed;
            } else if (next instanceof Event2) {
              let name = next.name;
              let handler = next.handler;
              loop$controlled = controlled;
              loop$path = path;
              loop$events = add_event(events2, path, name, handler);
              loop$old = remaining_old;
              loop$new = remaining_new;
              loop$added = prepend(next, added);
              loop$removed = prepend(prev, removed);
            } else {
              loop$controlled = controlled;
              loop$path = path;
              loop$events = events2;
              loop$old = remaining_old;
              loop$new = remaining_new;
              loop$added = prepend(next, added);
              loop$removed = prepend(prev, removed);
            }
          } else if (next instanceof Event2) {
            let name = next.name;
            let handler = next.handler;
            let has_changes = prev.prevent_default.kind !== next.prevent_default.kind || prev.stop_propagation.kind !== next.stop_propagation.kind || prev.debounce !== next.debounce || prev.throttle !== next.throttle;
            let _block;
            if (has_changes) {
              _block = prepend(next, added);
            } else {
              _block = added;
            }
            let added$1 = _block;
            loop$controlled = controlled;
            loop$path = path;
            loop$events = add_event(events2, path, name, handler);
            loop$old = remaining_old;
            loop$new = remaining_new;
            loop$added = added$1;
            loop$removed = removed;
          } else {
            let name = prev.name;
            loop$controlled = controlled;
            loop$path = path;
            loop$events = remove_event(events2, path, name);
            loop$old = remaining_old;
            loop$new = remaining_new;
            loop$added = prepend(next, added);
            loop$removed = prepend(prev, removed);
          }
        } else if (next instanceof Event2) {
          let name = next.name;
          let handler = next.handler;
          loop$controlled = controlled;
          loop$path = path;
          loop$events = add_event(events2, path, name, handler);
          loop$old = old;
          loop$new = remaining_new;
          loop$added = prepend(next, added);
          loop$removed = removed;
        } else {
          loop$controlled = controlled;
          loop$path = path;
          loop$events = events2;
          loop$old = old;
          loop$new = remaining_new;
          loop$added = prepend(next, added);
          loop$removed = removed;
        }
      }
    }
  }
  function is_controlled(cache, namespace, tag, path) {
    if (tag === "input" && namespace === "") {
      return has_dispatched_events(cache, path);
    } else if (tag === "select" && namespace === "") {
      return has_dispatched_events(cache, path);
    } else if (tag === "textarea" && namespace === "") {
      return has_dispatched_events(cache, path);
    } else {
      return false;
    }
  }
  function do_diff(loop$old, loop$old_keyed, loop$new, loop$new_keyed, loop$moved, loop$moved_offset, loop$removed, loop$node_index, loop$patch_index, loop$changes, loop$children, loop$path, loop$cache, loop$events) {
    while (true) {
      let old = loop$old;
      let old_keyed = loop$old_keyed;
      let new$5 = loop$new;
      let new_keyed = loop$new_keyed;
      let moved = loop$moved;
      let moved_offset = loop$moved_offset;
      let removed = loop$removed;
      let node_index = loop$node_index;
      let patch_index = loop$patch_index;
      let changes = loop$changes;
      let children = loop$children;
      let path = loop$path;
      let cache = loop$cache;
      let events2 = loop$events;
      if (old instanceof Empty) {
        if (new$5 instanceof Empty) {
          let _block;
          let $ = is_browser();
          if (changes instanceof Empty) {
            if (children instanceof Empty) {
              _block = new$3(patch_index, removed, changes, children);
            } else if (!$ && children.tail instanceof Empty && removed === 0) {
              let child2 = children.head;
              _block = add_parent(child2, patch_index);
            } else {
              _block = new$3(patch_index, removed, changes, children);
            }
          } else {
            _block = new$3(patch_index, removed, changes, children);
          }
          let patch = _block;
          return new PartialDiff(patch, cache, events2);
        } else {
          let $ = add_children(cache, events2, path, node_index, new$5);
          let cache$1 = $[0];
          let events$1 = $[1];
          let insert4 = insert3(new$5, node_index - moved_offset);
          let changes$1 = prepend(insert4, changes);
          let patch = new$3(patch_index, removed, changes$1, children);
          return new PartialDiff(patch, cache$1, events$1);
        }
      } else if (new$5 instanceof Empty) {
        let prev = old.head;
        let old$1 = old.tail;
        let $ = prev.key === "" || !has_key(moved, prev.key);
        if ($) {
          let events$1 = remove_child(
            cache,
            events2,
            path,
            node_index,
            prev
          );
          loop$old = old$1;
          loop$old_keyed = old_keyed;
          loop$new = new$5;
          loop$new_keyed = new_keyed;
          loop$moved = moved;
          loop$moved_offset = moved_offset;
          loop$removed = removed + 1;
          loop$node_index = node_index;
          loop$patch_index = patch_index;
          loop$changes = changes;
          loop$children = children;
          loop$path = path;
          loop$cache = cache;
          loop$events = events$1;
        } else {
          loop$old = old$1;
          loop$old_keyed = old_keyed;
          loop$new = new$5;
          loop$new_keyed = new_keyed;
          loop$moved = moved;
          loop$moved_offset = moved_offset;
          loop$removed = removed;
          loop$node_index = node_index;
          loop$patch_index = patch_index;
          loop$changes = changes;
          loop$children = children;
          loop$path = path;
          loop$cache = cache;
          loop$events = events2;
        }
      } else {
        let prev = old.head;
        let next = new$5.head;
        if (prev.key !== next.key) {
          let old_remaining = old.tail;
          let new_remaining = new$5.tail;
          let next_did_exist = has_key(old_keyed, next.key);
          let prev_does_exist = has_key(new_keyed, prev.key);
          if (prev_does_exist) {
            if (next_did_exist) {
              let $ = has_key(moved, prev.key);
              if ($) {
                loop$old = old_remaining;
                loop$old_keyed = old_keyed;
                loop$new = new$5;
                loop$new_keyed = new_keyed;
                loop$moved = moved;
                loop$moved_offset = moved_offset - 1;
                loop$removed = removed;
                loop$node_index = node_index;
                loop$patch_index = patch_index;
                loop$changes = changes;
                loop$children = children;
                loop$path = path;
                loop$cache = cache;
                loop$events = events2;
              } else {
                let match = get2(old_keyed, next.key);
                let before = node_index - moved_offset;
                let changes$1 = prepend(
                  move(next.key, before),
                  changes
                );
                let moved$1 = insert2(moved, next.key, void 0);
                loop$old = prepend(match, old);
                loop$old_keyed = old_keyed;
                loop$new = new$5;
                loop$new_keyed = new_keyed;
                loop$moved = moved$1;
                loop$moved_offset = moved_offset + 1;
                loop$removed = removed;
                loop$node_index = node_index;
                loop$patch_index = patch_index;
                loop$changes = changes$1;
                loop$children = children;
                loop$path = path;
                loop$cache = cache;
                loop$events = events2;
              }
            } else {
              let before = node_index - moved_offset;
              let $ = add_child(cache, events2, path, node_index, next);
              let cache$1 = $[0];
              let events$1 = $[1];
              let insert4 = insert3(singleton_list(next), before);
              let changes$1 = prepend(insert4, changes);
              loop$old = old;
              loop$old_keyed = old_keyed;
              loop$new = new_remaining;
              loop$new_keyed = new_keyed;
              loop$moved = moved;
              loop$moved_offset = moved_offset + 1;
              loop$removed = removed;
              loop$node_index = node_index + 1;
              loop$patch_index = patch_index;
              loop$changes = changes$1;
              loop$children = children;
              loop$path = path;
              loop$cache = cache$1;
              loop$events = events$1;
            }
          } else if (next_did_exist) {
            let index2 = node_index - moved_offset;
            let changes$1 = prepend(remove2(index2), changes);
            let events$1 = remove_child(
              cache,
              events2,
              path,
              node_index,
              prev
            );
            loop$old = old_remaining;
            loop$old_keyed = old_keyed;
            loop$new = new$5;
            loop$new_keyed = new_keyed;
            loop$moved = moved;
            loop$moved_offset = moved_offset - 1;
            loop$removed = removed;
            loop$node_index = node_index;
            loop$patch_index = patch_index;
            loop$changes = changes$1;
            loop$children = children;
            loop$path = path;
            loop$cache = cache;
            loop$events = events$1;
          } else {
            let change = replace2(node_index - moved_offset, next);
            let $ = replace_child(
              cache,
              events2,
              path,
              node_index,
              prev,
              next
            );
            let cache$1 = $[0];
            let events$1 = $[1];
            loop$old = old_remaining;
            loop$old_keyed = old_keyed;
            loop$new = new_remaining;
            loop$new_keyed = new_keyed;
            loop$moved = moved;
            loop$moved_offset = moved_offset;
            loop$removed = removed;
            loop$node_index = node_index + 1;
            loop$patch_index = patch_index;
            loop$changes = prepend(change, changes);
            loop$children = children;
            loop$path = path;
            loop$cache = cache$1;
            loop$events = events$1;
          }
        } else {
          let $ = old.head;
          if ($ instanceof Fragment) {
            let $1 = new$5.head;
            if ($1 instanceof Fragment) {
              let prev$1 = $;
              let old$1 = old.tail;
              let next$1 = $1;
              let new$1 = new$5.tail;
              let $2 = do_diff(
                prev$1.children,
                prev$1.keyed_children,
                next$1.children,
                next$1.keyed_children,
                empty2(),
                0,
                0,
                0,
                node_index,
                empty_list,
                empty_list,
                add2(path, node_index, next$1.key),
                cache,
                events2
              );
              let patch = $2.patch;
              let cache$1 = $2.cache;
              let events$1 = $2.events;
              let _block;
              if (patch.changes instanceof Empty && patch.children instanceof Empty && patch.removed === 0) {
                _block = children;
              } else {
                _block = prepend(patch, children);
              }
              let children$1 = _block;
              loop$old = old$1;
              loop$old_keyed = old_keyed;
              loop$new = new$1;
              loop$new_keyed = new_keyed;
              loop$moved = moved;
              loop$moved_offset = moved_offset;
              loop$removed = removed;
              loop$node_index = node_index + 1;
              loop$patch_index = patch_index;
              loop$changes = changes;
              loop$children = children$1;
              loop$path = path;
              loop$cache = cache$1;
              loop$events = events$1;
            } else {
              let prev$1 = $;
              let old_remaining$1 = old.tail;
              let next$1 = $1;
              let new_remaining$1 = new$5.tail;
              let change = replace2(node_index - moved_offset, next$1);
              let $2 = replace_child(
                cache,
                events2,
                path,
                node_index,
                prev$1,
                next$1
              );
              let cache$1 = $2[0];
              let events$1 = $2[1];
              loop$old = old_remaining$1;
              loop$old_keyed = old_keyed;
              loop$new = new_remaining$1;
              loop$new_keyed = new_keyed;
              loop$moved = moved;
              loop$moved_offset = moved_offset;
              loop$removed = removed;
              loop$node_index = node_index + 1;
              loop$patch_index = patch_index;
              loop$changes = prepend(change, changes);
              loop$children = children;
              loop$path = path;
              loop$cache = cache$1;
              loop$events = events$1;
            }
          } else if ($ instanceof Element) {
            let $1 = new$5.head;
            if ($1 instanceof Element) {
              let prev$1 = $;
              let next$1 = $1;
              if (prev$1.namespace === next$1.namespace && prev$1.tag === next$1.tag) {
                let old$1 = old.tail;
                let new$1 = new$5.tail;
                let child_path = add2(path, node_index, next$1.key);
                let controlled = is_controlled(
                  cache,
                  next$1.namespace,
                  next$1.tag,
                  child_path
                );
                let $2 = diff_attributes(
                  controlled,
                  child_path,
                  events2,
                  prev$1.attributes,
                  next$1.attributes,
                  empty_list,
                  empty_list
                );
                let added_attrs = $2.added;
                let removed_attrs = $2.removed;
                let events$1 = $2.events;
                let _block;
                if (added_attrs instanceof Empty && removed_attrs instanceof Empty) {
                  _block = empty_list;
                } else {
                  _block = singleton_list(
                    update(added_attrs, removed_attrs)
                  );
                }
                let initial_child_changes = _block;
                let $3 = do_diff(
                  prev$1.children,
                  prev$1.keyed_children,
                  next$1.children,
                  next$1.keyed_children,
                  empty2(),
                  0,
                  0,
                  0,
                  node_index,
                  initial_child_changes,
                  empty_list,
                  child_path,
                  cache,
                  events$1
                );
                let patch = $3.patch;
                let cache$1 = $3.cache;
                let events$2 = $3.events;
                let _block$1;
                if (patch.changes instanceof Empty && patch.children instanceof Empty && patch.removed === 0) {
                  _block$1 = children;
                } else {
                  _block$1 = prepend(patch, children);
                }
                let children$1 = _block$1;
                loop$old = old$1;
                loop$old_keyed = old_keyed;
                loop$new = new$1;
                loop$new_keyed = new_keyed;
                loop$moved = moved;
                loop$moved_offset = moved_offset;
                loop$removed = removed;
                loop$node_index = node_index + 1;
                loop$patch_index = patch_index;
                loop$changes = changes;
                loop$children = children$1;
                loop$path = path;
                loop$cache = cache$1;
                loop$events = events$2;
              } else {
                let prev$2 = $;
                let old_remaining$1 = old.tail;
                let next$2 = $1;
                let new_remaining$1 = new$5.tail;
                let change = replace2(node_index - moved_offset, next$2);
                let $4 = replace_child(
                  cache,
                  events2,
                  path,
                  node_index,
                  prev$2,
                  next$2
                );
                let cache$2 = $4[0];
                let events$3 = $4[1];
                loop$old = old_remaining$1;
                loop$old_keyed = old_keyed;
                loop$new = new_remaining$1;
                loop$new_keyed = new_keyed;
                loop$moved = moved;
                loop$moved_offset = moved_offset;
                loop$removed = removed;
                loop$node_index = node_index + 1;
                loop$patch_index = patch_index;
                loop$changes = prepend(change, changes);
                loop$children = children;
                loop$path = path;
                loop$cache = cache$2;
                loop$events = events$3;
              }
            } else {
              let prev$1 = $;
              let old_remaining$1 = old.tail;
              let next$1 = $1;
              let new_remaining$1 = new$5.tail;
              let change = replace2(node_index - moved_offset, next$1);
              let $2 = replace_child(
                cache,
                events2,
                path,
                node_index,
                prev$1,
                next$1
              );
              let cache$1 = $2[0];
              let events$1 = $2[1];
              loop$old = old_remaining$1;
              loop$old_keyed = old_keyed;
              loop$new = new_remaining$1;
              loop$new_keyed = new_keyed;
              loop$moved = moved;
              loop$moved_offset = moved_offset;
              loop$removed = removed;
              loop$node_index = node_index + 1;
              loop$patch_index = patch_index;
              loop$changes = prepend(change, changes);
              loop$children = children;
              loop$path = path;
              loop$cache = cache$1;
              loop$events = events$1;
            }
          } else if ($ instanceof Text) {
            let $1 = new$5.head;
            if ($1 instanceof Text) {
              let prev$1 = $;
              let next$1 = $1;
              if (prev$1.content === next$1.content) {
                let old$1 = old.tail;
                let new$1 = new$5.tail;
                loop$old = old$1;
                loop$old_keyed = old_keyed;
                loop$new = new$1;
                loop$new_keyed = new_keyed;
                loop$moved = moved;
                loop$moved_offset = moved_offset;
                loop$removed = removed;
                loop$node_index = node_index + 1;
                loop$patch_index = patch_index;
                loop$changes = changes;
                loop$children = children;
                loop$path = path;
                loop$cache = cache;
                loop$events = events2;
              } else {
                let old$2 = old.tail;
                let next$2 = $1;
                let new$22 = new$5.tail;
                let child2 = new$3(
                  node_index,
                  0,
                  singleton_list(replace_text(next$2.content)),
                  empty_list
                );
                loop$old = old$2;
                loop$old_keyed = old_keyed;
                loop$new = new$22;
                loop$new_keyed = new_keyed;
                loop$moved = moved;
                loop$moved_offset = moved_offset;
                loop$removed = removed;
                loop$node_index = node_index + 1;
                loop$patch_index = patch_index;
                loop$changes = changes;
                loop$children = prepend(child2, children);
                loop$path = path;
                loop$cache = cache;
                loop$events = events2;
              }
            } else {
              let prev$1 = $;
              let old_remaining$1 = old.tail;
              let next$1 = $1;
              let new_remaining$1 = new$5.tail;
              let change = replace2(node_index - moved_offset, next$1);
              let $2 = replace_child(
                cache,
                events2,
                path,
                node_index,
                prev$1,
                next$1
              );
              let cache$1 = $2[0];
              let events$1 = $2[1];
              loop$old = old_remaining$1;
              loop$old_keyed = old_keyed;
              loop$new = new_remaining$1;
              loop$new_keyed = new_keyed;
              loop$moved = moved;
              loop$moved_offset = moved_offset;
              loop$removed = removed;
              loop$node_index = node_index + 1;
              loop$patch_index = patch_index;
              loop$changes = prepend(change, changes);
              loop$children = children;
              loop$path = path;
              loop$cache = cache$1;
              loop$events = events$1;
            }
          } else if ($ instanceof UnsafeInnerHtml) {
            let $1 = new$5.head;
            if ($1 instanceof UnsafeInnerHtml) {
              let prev$1 = $;
              let old$1 = old.tail;
              let next$1 = $1;
              let new$1 = new$5.tail;
              let child_path = add2(path, node_index, next$1.key);
              let $2 = diff_attributes(
                false,
                child_path,
                events2,
                prev$1.attributes,
                next$1.attributes,
                empty_list,
                empty_list
              );
              let added_attrs = $2.added;
              let removed_attrs = $2.removed;
              let events$1 = $2.events;
              let _block;
              if (added_attrs instanceof Empty && removed_attrs instanceof Empty) {
                _block = empty_list;
              } else {
                _block = singleton_list(
                  update(added_attrs, removed_attrs)
                );
              }
              let child_changes = _block;
              let _block$1;
              let $3 = prev$1.inner_html === next$1.inner_html;
              if ($3) {
                _block$1 = child_changes;
              } else {
                _block$1 = prepend(
                  replace_inner_html(next$1.inner_html),
                  child_changes
                );
              }
              let child_changes$1 = _block$1;
              let _block$2;
              if (child_changes$1 instanceof Empty) {
                _block$2 = children;
              } else {
                _block$2 = prepend(
                  new$3(
                    node_index,
                    0,
                    child_changes$1,
                    empty_list
                  ),
                  children
                );
              }
              let children$1 = _block$2;
              loop$old = old$1;
              loop$old_keyed = old_keyed;
              loop$new = new$1;
              loop$new_keyed = new_keyed;
              loop$moved = moved;
              loop$moved_offset = moved_offset;
              loop$removed = removed;
              loop$node_index = node_index + 1;
              loop$patch_index = patch_index;
              loop$changes = changes;
              loop$children = children$1;
              loop$path = path;
              loop$cache = cache;
              loop$events = events$1;
            } else {
              let prev$1 = $;
              let old_remaining$1 = old.tail;
              let next$1 = $1;
              let new_remaining$1 = new$5.tail;
              let change = replace2(node_index - moved_offset, next$1);
              let $2 = replace_child(
                cache,
                events2,
                path,
                node_index,
                prev$1,
                next$1
              );
              let cache$1 = $2[0];
              let events$1 = $2[1];
              loop$old = old_remaining$1;
              loop$old_keyed = old_keyed;
              loop$new = new_remaining$1;
              loop$new_keyed = new_keyed;
              loop$moved = moved;
              loop$moved_offset = moved_offset;
              loop$removed = removed;
              loop$node_index = node_index + 1;
              loop$patch_index = patch_index;
              loop$changes = prepend(change, changes);
              loop$children = children;
              loop$path = path;
              loop$cache = cache$1;
              loop$events = events$1;
            }
          } else if ($ instanceof Map2) {
            let $1 = new$5.head;
            if ($1 instanceof Map2) {
              let prev$1 = $;
              let old$1 = old.tail;
              let next$1 = $1;
              let new$1 = new$5.tail;
              let child_path = add2(path, node_index, next$1.key);
              let child_key = child(child_path);
              let $2 = do_diff(
                singleton_list(prev$1.child),
                empty2(),
                singleton_list(next$1.child),
                empty2(),
                empty2(),
                0,
                0,
                0,
                node_index,
                empty_list,
                empty_list,
                subtree(child_path),
                cache,
                get_subtree(events2, child_key, prev$1.mapper)
              );
              let patch = $2.patch;
              let cache$1 = $2.cache;
              let child_events = $2.events;
              let events$1 = update_subtree(
                events2,
                child_key,
                next$1.mapper,
                child_events
              );
              let _block;
              if (patch.changes instanceof Empty && patch.children instanceof Empty && patch.removed === 0) {
                _block = children;
              } else {
                _block = prepend(patch, children);
              }
              let children$1 = _block;
              loop$old = old$1;
              loop$old_keyed = old_keyed;
              loop$new = new$1;
              loop$new_keyed = new_keyed;
              loop$moved = moved;
              loop$moved_offset = moved_offset;
              loop$removed = removed;
              loop$node_index = node_index + 1;
              loop$patch_index = patch_index;
              loop$changes = changes;
              loop$children = children$1;
              loop$path = path;
              loop$cache = cache$1;
              loop$events = events$1;
            } else {
              let prev$1 = $;
              let old_remaining$1 = old.tail;
              let next$1 = $1;
              let new_remaining$1 = new$5.tail;
              let change = replace2(node_index - moved_offset, next$1);
              let $2 = replace_child(
                cache,
                events2,
                path,
                node_index,
                prev$1,
                next$1
              );
              let cache$1 = $2[0];
              let events$1 = $2[1];
              loop$old = old_remaining$1;
              loop$old_keyed = old_keyed;
              loop$new = new_remaining$1;
              loop$new_keyed = new_keyed;
              loop$moved = moved;
              loop$moved_offset = moved_offset;
              loop$removed = removed;
              loop$node_index = node_index + 1;
              loop$patch_index = patch_index;
              loop$changes = prepend(change, changes);
              loop$children = children;
              loop$path = path;
              loop$cache = cache$1;
              loop$events = events$1;
            }
          } else {
            let $1 = new$5.head;
            if ($1 instanceof Memo) {
              let prev$1 = $;
              let old$1 = old.tail;
              let next$1 = $1;
              let new$1 = new$5.tail;
              let $2 = equal_lists(prev$1.dependencies, next$1.dependencies);
              if ($2) {
                let cache$1 = keep_memo(cache, prev$1.view, next$1.view);
                loop$old = old$1;
                loop$old_keyed = old_keyed;
                loop$new = new$1;
                loop$new_keyed = new_keyed;
                loop$moved = moved;
                loop$moved_offset = moved_offset;
                loop$removed = removed;
                loop$node_index = node_index + 1;
                loop$patch_index = patch_index;
                loop$changes = changes;
                loop$children = children;
                loop$path = path;
                loop$cache = cache$1;
                loop$events = events2;
              } else {
                let prev_node = get_old_memo(
                  cache,
                  prev$1.view,
                  prev$1.view
                );
                let next_node = next$1.view();
                let cache$1 = add_memo(cache, next$1.view, next_node);
                loop$old = prepend(prev_node, old$1);
                loop$old_keyed = old_keyed;
                loop$new = prepend(next_node, new$1);
                loop$new_keyed = new_keyed;
                loop$moved = moved;
                loop$moved_offset = moved_offset;
                loop$removed = removed;
                loop$node_index = node_index;
                loop$patch_index = patch_index;
                loop$changes = changes;
                loop$children = children;
                loop$path = path;
                loop$cache = cache$1;
                loop$events = events2;
              }
            } else {
              let prev$1 = $;
              let old_remaining$1 = old.tail;
              let next$1 = $1;
              let new_remaining$1 = new$5.tail;
              let change = replace2(node_index - moved_offset, next$1);
              let $2 = replace_child(
                cache,
                events2,
                path,
                node_index,
                prev$1,
                next$1
              );
              let cache$1 = $2[0];
              let events$1 = $2[1];
              loop$old = old_remaining$1;
              loop$old_keyed = old_keyed;
              loop$new = new_remaining$1;
              loop$new_keyed = new_keyed;
              loop$moved = moved;
              loop$moved_offset = moved_offset;
              loop$removed = removed;
              loop$node_index = node_index + 1;
              loop$patch_index = patch_index;
              loop$changes = prepend(change, changes);
              loop$children = children;
              loop$path = path;
              loop$cache = cache$1;
              loop$events = events$1;
            }
          }
        }
      }
    }
  }
  function diff(cache, old, new$5) {
    let cache$1 = tick(cache);
    let $ = do_diff(
      singleton_list(old),
      empty2(),
      singleton_list(new$5),
      empty2(),
      empty2(),
      0,
      0,
      0,
      0,
      empty_list,
      empty_list,
      root,
      cache$1,
      events(cache$1)
    );
    let patch = $.patch;
    let cache$2 = $.cache;
    let events2 = $.events;
    return new Diff(patch, update_events(cache$2, events2));
  }

  // build/dev/javascript/lustre/lustre/internals/list.ffi.mjs
  var iterate = (list4, callback) => {
    if (Array.isArray(list4)) {
      for (let i = 0; i < list4.length; i++) {
        callback(list4[i]);
      }
    } else if (list4) {
      for (list4; List$NonEmpty$rest(list4); list4 = List$NonEmpty$rest(list4)) {
        callback(List$NonEmpty$first(list4));
      }
    }
  };
  var append4 = (a, b) => {
    if (!List$NonEmpty$rest(a)) {
      return b;
    } else if (!List$NonEmpty$rest(b)) {
      return a;
    } else {
      return append2(a, b);
    }
  };

  // build/dev/javascript/lustre/lustre/internals/constants.ffi.mjs
  var NAMESPACE_HTML = "http://www.w3.org/1999/xhtml";
  var ELEMENT_NODE = 1;
  var TEXT_NODE = 3;
  var COMMENT_NODE = 8;
  var SUPPORTS_MOVE_BEFORE = !!globalThis.HTMLElement?.prototype?.moveBefore;

  // build/dev/javascript/lustre/lustre/vdom/reconciler.ffi.mjs
  var setTimeout = globalThis.setTimeout;
  var clearTimeout = globalThis.clearTimeout;
  var createElementNS = (ns, name) => globalThis.document.createElementNS(ns, name);
  var createTextNode = (data) => globalThis.document.createTextNode(data);
  var createComment = (data) => globalThis.document.createComment(data);
  var createDocumentFragment = () => globalThis.document.createDocumentFragment();
  var insertBefore = (parent, node, reference) => parent.insertBefore(node, reference);
  var moveBefore = SUPPORTS_MOVE_BEFORE ? (parent, node, reference) => parent.moveBefore(node, reference) : insertBefore;
  var removeChild = (parent, child2) => parent.removeChild(child2);
  var getAttribute = (node, name) => node.getAttribute(name);
  var setAttribute = (node, name, value) => node.setAttribute(name, value);
  var removeAttribute = (node, name) => node.removeAttribute(name);
  var addEventListener = (node, name, handler, options) => node.addEventListener(name, handler, options);
  var removeEventListener = (node, name, handler) => node.removeEventListener(name, handler);
  var setInnerHtml = (node, innerHtml) => node.innerHTML = innerHtml;
  var setData = (node, data) => node.data = data;
  var meta = Symbol("lustre");
  var MetadataNode = class {
    constructor(kind, parent, node, key) {
      this.kind = kind;
      this.key = key;
      this.parent = parent;
      this.children = [];
      this.node = node;
      this.endNode = null;
      this.handlers = /* @__PURE__ */ new Map();
      this.throttles = /* @__PURE__ */ new Map();
      this.debouncers = /* @__PURE__ */ new Map();
    }
    get isVirtual() {
      return this.kind === fragment_kind || this.kind === map_kind;
    }
    get parentNode() {
      return this.isVirtual ? this.node.parentNode : this.node;
    }
  };
  var insertMetadataChild = (kind, parent, node, index2, key) => {
    const child2 = new MetadataNode(kind, parent, node, key);
    node[meta] = child2;
    parent?.children.splice(index2, 0, child2);
    return child2;
  };
  var getPath = (node) => {
    let path = "";
    for (let current = node[meta]; current.parent; current = current.parent) {
      const separator = current.parent && current.parent.kind === map_kind ? separator_subtree : separator_element;
      if (current.key) {
        path = `${separator}${current.key}${path}`;
      } else {
        const index2 = current.parent.children.indexOf(current);
        path = `${separator}${index2}${path}`;
      }
    }
    return path.slice(1);
  };
  var _root, _decodeEvent, _dispatch, _debug, _memos, _stack, _Reconciler_instances, reconcile_fn, patch_fn, insert_fn, replace_fn, getReference_fn, move_fn, moveChildren_fn, moveChild_fn, remove_fn, removeChildren_fn, removeDebouncers_fn, update_fn, replaceText_fn, replaceInnerHtml_fn, insertChildren_fn, insertChild_fn, createElement_fn, createTextNode_fn, createHead_fn, createAttribute_fn, updateDebounceThrottle_fn, handleEvent_fn;
  var Reconciler = class {
    constructor(root2, decodeEvent, dispatch2, { debug = false } = {}) {
      __privateAdd(this, _Reconciler_instances);
      __privateAdd(this, _root, null);
      __privateAdd(this, _decodeEvent);
      __privateAdd(this, _dispatch);
      __privateAdd(this, _debug, false);
      // PATCHING ------------------------------------------------------------------
      __privateAdd(this, _memos);
      __privateAdd(this, _stack, []);
      __privateSet(this, _root, root2);
      __privateSet(this, _decodeEvent, decodeEvent);
      __privateSet(this, _dispatch, dispatch2);
      __privateSet(this, _debug, debug);
    }
    mount(vdom) {
      insertMetadataChild(element_kind, null, __privateGet(this, _root), 0, null);
      __privateMethod(this, _Reconciler_instances, insertChild_fn).call(this, __privateGet(this, _root), null, __privateGet(this, _root)[meta], 0, vdom);
    }
    push(patch, memos2 = null) {
      __privateSet(this, _memos, memos2);
      __privateGet(this, _stack).push({ node: __privateGet(this, _root)[meta], patch });
      __privateMethod(this, _Reconciler_instances, reconcile_fn).call(this);
    }
  };
  _root = new WeakMap();
  _decodeEvent = new WeakMap();
  _dispatch = new WeakMap();
  _debug = new WeakMap();
  _memos = new WeakMap();
  _stack = new WeakMap();
  _Reconciler_instances = new WeakSet();
  reconcile_fn = function() {
    const stack = __privateGet(this, _stack);
    while (stack.length) {
      let { node, patch } = stack.pop();
      const { path, changes, removed, children: childPatches } = patch;
      iterate(path, (index2) => {
        node = node.children[index2];
      });
      const { children: childNodes } = node;
      iterate(changes, (change) => __privateMethod(this, _Reconciler_instances, patch_fn).call(this, node, change));
      if (removed) {
        __privateMethod(this, _Reconciler_instances, removeChildren_fn).call(this, node, childNodes.length - removed, removed);
      }
      iterate(childPatches, (childPatch) => {
        const child2 = childNodes[childPatch.index | 0];
        __privateGet(this, _stack).push({ node: child2, patch: childPatch });
      });
    }
  };
  patch_fn = function(node, change) {
    switch (change.kind) {
      case replace_text_kind:
        __privateMethod(this, _Reconciler_instances, replaceText_fn).call(this, node, change);
        break;
      case replace_inner_html_kind:
        __privateMethod(this, _Reconciler_instances, replaceInnerHtml_fn).call(this, node, change);
        break;
      case update_kind:
        __privateMethod(this, _Reconciler_instances, update_fn).call(this, node, change);
        break;
      case move_kind:
        __privateMethod(this, _Reconciler_instances, move_fn).call(this, node, change);
        break;
      case remove_kind:
        __privateMethod(this, _Reconciler_instances, remove_fn).call(this, node, change);
        break;
      case replace_kind:
        __privateMethod(this, _Reconciler_instances, replace_fn).call(this, node, change);
        break;
      case insert_kind:
        __privateMethod(this, _Reconciler_instances, insert_fn).call(this, node, change);
        break;
    }
  };
  // CHANGES -------------------------------------------------------------------
  insert_fn = function(parent, { children, before }) {
    const fragment4 = createDocumentFragment();
    const beforeEl = __privateMethod(this, _Reconciler_instances, getReference_fn).call(this, parent, before);
    __privateMethod(this, _Reconciler_instances, insertChildren_fn).call(this, fragment4, null, parent, before | 0, children);
    insertBefore(parent.parentNode, fragment4, beforeEl);
  };
  replace_fn = function(parent, { index: index2, with: child2 }) {
    __privateMethod(this, _Reconciler_instances, removeChildren_fn).call(this, parent, index2 | 0, 1);
    const beforeEl = __privateMethod(this, _Reconciler_instances, getReference_fn).call(this, parent, index2);
    __privateMethod(this, _Reconciler_instances, insertChild_fn).call(this, parent.parentNode, beforeEl, parent, index2 | 0, child2);
  };
  getReference_fn = function(node, index2) {
    index2 = index2 | 0;
    const { children } = node;
    const childCount = children.length;
    if (index2 < childCount) return children[index2].node;
    if (node.endNode) return node.endNode;
    if (!node.isVirtual) return null;
    while (node.isVirtual && node.children.length) {
      if (node.endNode) return node.endNode.nextSibling;
      node = node.children[node.children.length - 1];
    }
    return node.node.nextSibling;
  };
  move_fn = function(parent, { key, before }) {
    before = before | 0;
    const { children, parentNode } = parent;
    const beforeEl = children[before].node;
    let prev = children[before];
    for (let i = before + 1; i < children.length; ++i) {
      const next = children[i];
      children[i] = prev;
      prev = next;
      if (next.key === key) {
        children[before] = next;
        break;
      }
    }
    __privateMethod(this, _Reconciler_instances, moveChild_fn).call(this, parentNode, prev, beforeEl);
  };
  moveChildren_fn = function(domParent, children, beforeEl) {
    for (let i = 0; i < children.length; ++i) {
      __privateMethod(this, _Reconciler_instances, moveChild_fn).call(this, domParent, children[i], beforeEl);
    }
  };
  moveChild_fn = function(domParent, child2, beforeEl) {
    moveBefore(domParent, child2.node, beforeEl);
    if (child2.isVirtual) {
      __privateMethod(this, _Reconciler_instances, moveChildren_fn).call(this, domParent, child2.children, beforeEl);
    }
    if (child2.endNode) {
      moveBefore(domParent, child2.endNode, beforeEl);
    }
  };
  remove_fn = function(parent, { index: index2 }) {
    __privateMethod(this, _Reconciler_instances, removeChildren_fn).call(this, parent, index2, 1);
  };
  removeChildren_fn = function(parent, index2, count) {
    const { children, parentNode } = parent;
    const deleted = children.splice(index2, count);
    for (let i = 0; i < deleted.length; ++i) {
      const child2 = deleted[i];
      const { node, endNode, isVirtual, children: nestedChildren } = child2;
      removeChild(parentNode, node);
      if (endNode) {
        removeChild(parentNode, endNode);
      }
      __privateMethod(this, _Reconciler_instances, removeDebouncers_fn).call(this, child2);
      if (isVirtual) {
        deleted.push(...nestedChildren);
      }
    }
  };
  removeDebouncers_fn = function(node) {
    const { debouncers, children } = node;
    for (const { timeout } of debouncers.values()) {
      if (timeout) {
        clearTimeout(timeout);
      }
    }
    debouncers.clear();
    iterate(children, (child2) => __privateMethod(this, _Reconciler_instances, removeDebouncers_fn).call(this, child2));
  };
  update_fn = function({ node, handlers, throttles, debouncers }, { added, removed }) {
    iterate(removed, ({ name }) => {
      if (handlers.delete(name)) {
        removeEventListener(node, name, handleEvent);
        __privateMethod(this, _Reconciler_instances, updateDebounceThrottle_fn).call(this, throttles, name, 0);
        __privateMethod(this, _Reconciler_instances, updateDebounceThrottle_fn).call(this, debouncers, name, 0);
      } else {
        removeAttribute(node, name);
        SYNCED_ATTRIBUTES[name]?.removed?.(node, name);
      }
    });
    iterate(added, (attribute3) => __privateMethod(this, _Reconciler_instances, createAttribute_fn).call(this, node, attribute3));
  };
  replaceText_fn = function({ node }, { content }) {
    setData(node, content ?? "");
  };
  replaceInnerHtml_fn = function({ node }, { inner_html }) {
    setInnerHtml(node, inner_html ?? "");
  };
  // INSERT --------------------------------------------------------------------
  insertChildren_fn = function(domParent, beforeEl, metaParent, index2, children) {
    iterate(
      children,
      (child2) => __privateMethod(this, _Reconciler_instances, insertChild_fn).call(this, domParent, beforeEl, metaParent, index2++, child2)
    );
  };
  insertChild_fn = function(domParent, beforeEl, metaParent, index2, vnode) {
    switch (vnode.kind) {
      case element_kind: {
        const node = __privateMethod(this, _Reconciler_instances, createElement_fn).call(this, metaParent, index2, vnode);
        __privateMethod(this, _Reconciler_instances, insertChildren_fn).call(this, node, null, node[meta], 0, vnode.children);
        insertBefore(domParent, node, beforeEl);
        break;
      }
      case text_kind: {
        const node = __privateMethod(this, _Reconciler_instances, createTextNode_fn).call(this, metaParent, index2, vnode);
        insertBefore(domParent, node, beforeEl);
        break;
      }
      case fragment_kind: {
        const marker = "lustre:fragment";
        const head = __privateMethod(this, _Reconciler_instances, createHead_fn).call(this, marker, metaParent, index2, vnode);
        insertBefore(domParent, head, beforeEl);
        __privateMethod(this, _Reconciler_instances, insertChildren_fn).call(this, domParent, beforeEl, head[meta], 0, vnode.children);
        if (__privateGet(this, _debug)) {
          head[meta].endNode = createComment(` /${marker} `);
          insertBefore(domParent, head[meta].endNode, beforeEl);
        }
        break;
      }
      case unsafe_inner_html_kind: {
        const node = __privateMethod(this, _Reconciler_instances, createElement_fn).call(this, metaParent, index2, vnode);
        __privateMethod(this, _Reconciler_instances, replaceInnerHtml_fn).call(this, { node }, vnode);
        insertBefore(domParent, node, beforeEl);
        break;
      }
      case map_kind: {
        const head = __privateMethod(this, _Reconciler_instances, createHead_fn).call(this, "lustre:map", metaParent, index2, vnode);
        insertBefore(domParent, head, beforeEl);
        __privateMethod(this, _Reconciler_instances, insertChild_fn).call(this, domParent, beforeEl, head[meta], 0, vnode.child);
        break;
      }
      case memo_kind: {
        const child2 = __privateGet(this, _memos)?.get(vnode.view) ?? vnode.view();
        __privateMethod(this, _Reconciler_instances, insertChild_fn).call(this, domParent, beforeEl, metaParent, index2, child2);
        break;
      }
    }
  };
  createElement_fn = function(parent, index2, { kind, key, tag, namespace, attributes }) {
    const node = createElementNS(namespace || NAMESPACE_HTML, tag);
    insertMetadataChild(kind, parent, node, index2, key);
    if (__privateGet(this, _debug) && key) {
      setAttribute(node, "data-lustre-key", key);
    }
    iterate(attributes, (attribute3) => __privateMethod(this, _Reconciler_instances, createAttribute_fn).call(this, node, attribute3));
    return node;
  };
  createTextNode_fn = function(parent, index2, { kind, key, content }) {
    const node = createTextNode(content ?? "");
    insertMetadataChild(kind, parent, node, index2, key);
    return node;
  };
  createHead_fn = function(marker, parent, index2, { kind, key }) {
    const node = __privateGet(this, _debug) ? createComment(markerComment(marker, key)) : createTextNode("");
    insertMetadataChild(kind, parent, node, index2, key);
    return node;
  };
  createAttribute_fn = function(node, attribute3) {
    const { debouncers, handlers, throttles } = node[meta];
    const {
      kind,
      name,
      value,
      prevent_default: prevent,
      debounce: debounceDelay,
      throttle: throttleDelay
    } = attribute3;
    switch (kind) {
      case attribute_kind: {
        const valueOrDefault = value ?? "";
        if (name === "virtual:defaultValue") {
          node.defaultValue = valueOrDefault;
          return;
        } else if (name === "virtual:defaultChecked") {
          node.defaultChecked = true;
          return;
        } else if (name === "virtual:defaultSelected") {
          node.defaultSelected = true;
          return;
        }
        if (valueOrDefault !== getAttribute(node, name)) {
          setAttribute(node, name, valueOrDefault);
        }
        SYNCED_ATTRIBUTES[name]?.added?.(node, valueOrDefault);
        break;
      }
      case property_kind:
        node[name] = value;
        break;
      case event_kind: {
        if (handlers.has(name)) {
          removeEventListener(node, name, handleEvent);
        }
        const passive = prevent.kind === never_kind;
        addEventListener(node, name, handleEvent, { passive });
        __privateMethod(this, _Reconciler_instances, updateDebounceThrottle_fn).call(this, throttles, name, throttleDelay);
        __privateMethod(this, _Reconciler_instances, updateDebounceThrottle_fn).call(this, debouncers, name, debounceDelay);
        handlers.set(name, (event2) => __privateMethod(this, _Reconciler_instances, handleEvent_fn).call(this, attribute3, event2));
        break;
      }
    }
  };
  updateDebounceThrottle_fn = function(map6, name, delay) {
    const debounceOrThrottle = map6.get(name);
    if (delay > 0) {
      if (debounceOrThrottle) {
        debounceOrThrottle.delay = delay;
      } else {
        map6.set(name, { delay });
      }
    } else if (debounceOrThrottle) {
      const { timeout } = debounceOrThrottle;
      if (timeout) {
        clearTimeout(timeout);
      }
      map6.delete(name);
    }
  };
  handleEvent_fn = function(attribute3, event2) {
    const { currentTarget, type } = event2;
    const { debouncers, throttles } = currentTarget[meta];
    const path = getPath(currentTarget);
    const {
      prevent_default: prevent,
      stop_propagation: stop,
      include
    } = attribute3;
    if (prevent.kind === always_kind) event2.preventDefault();
    if (stop.kind === always_kind) event2.stopPropagation();
    if (type === "submit") {
      event2.detail ?? (event2.detail = {});
      event2.detail.formData = [
        ...new FormData(event2.target, event2.submitter).entries()
      ];
    }
    const data = __privateGet(this, _decodeEvent).call(this, event2, path, type, include);
    const throttle = throttles.get(type);
    if (throttle) {
      const now = Date.now();
      const last = throttle.last || 0;
      if (now > last + throttle.delay) {
        throttle.last = now;
        throttle.lastEvent = event2;
        __privateGet(this, _dispatch).call(this, event2, data);
      }
    }
    const debounce = debouncers.get(type);
    if (debounce) {
      clearTimeout(debounce.timeout);
      debounce.timeout = setTimeout(() => {
        if (event2 === throttles.get(type)?.lastEvent) return;
        __privateGet(this, _dispatch).call(this, event2, data);
      }, debounce.delay);
    }
    if (!throttle && !debounce) {
      __privateGet(this, _dispatch).call(this, event2, data);
    }
  };
  var markerComment = (marker, key) => {
    if (key) {
      return ` ${marker} key="${escape(key)}" `;
    } else {
      return ` ${marker} `;
    }
  };
  var handleEvent = (event2) => {
    const { currentTarget, type } = event2;
    const handler = currentTarget[meta].handlers.get(type);
    handler(event2);
  };
  var syncedBooleanAttribute = /* @__NO_SIDE_EFFECTS__ */ (name) => {
    return {
      added(node) {
        node[name] = true;
      },
      removed(node) {
        node[name] = false;
      }
    };
  };
  var syncedAttribute = /* @__NO_SIDE_EFFECTS__ */ (name) => {
    return {
      added(node, value) {
        node[name] = value;
      }
    };
  };
  var SYNCED_ATTRIBUTES = {
    checked: /* @__PURE__ */ syncedBooleanAttribute("checked"),
    selected: /* @__PURE__ */ syncedBooleanAttribute("selected"),
    value: /* @__PURE__ */ syncedAttribute("value"),
    autofocus: {
      added(node) {
        queueMicrotask(() => {
          node.focus?.();
        });
      }
    },
    autoplay: {
      added(node) {
        try {
          node.play?.();
        } catch (e) {
          console.error(e);
        }
      }
    }
  };

  // build/dev/javascript/lustre/lustre/element/keyed.mjs
  function do_extract_keyed_children(loop$key_children_pairs, loop$keyed_children, loop$children) {
    while (true) {
      let key_children_pairs = loop$key_children_pairs;
      let keyed_children = loop$keyed_children;
      let children = loop$children;
      if (key_children_pairs instanceof Empty) {
        return [keyed_children, reverse(children)];
      } else {
        let rest = key_children_pairs.tail;
        let key = key_children_pairs.head[0];
        let element$1 = key_children_pairs.head[1];
        let keyed_element = to_keyed(key, element$1);
        let _block;
        if (key === "") {
          _block = keyed_children;
        } else {
          _block = insert2(keyed_children, key, keyed_element);
        }
        let keyed_children$1 = _block;
        let children$1 = prepend(keyed_element, children);
        loop$key_children_pairs = rest;
        loop$keyed_children = keyed_children$1;
        loop$children = children$1;
      }
    }
  }
  function extract_keyed_children(children) {
    return do_extract_keyed_children(
      children,
      empty2(),
      empty_list
    );
  }
  function element3(tag, attributes, children) {
    let $ = extract_keyed_children(children);
    let keyed_children = $[0];
    let children$1 = $[1];
    return element(
      "",
      "",
      tag,
      attributes,
      children$1,
      keyed_children,
      false,
      is_void_html_element(tag, "")
    );
  }
  function namespaced2(namespace, tag, attributes, children) {
    let $ = extract_keyed_children(children);
    let keyed_children = $[0];
    let children$1 = $[1];
    return element(
      "",
      namespace,
      tag,
      attributes,
      children$1,
      keyed_children,
      false,
      is_void_html_element(tag, namespace)
    );
  }
  function fragment3(children) {
    let $ = extract_keyed_children(children);
    let keyed_children = $[0];
    let children$1 = $[1];
    return fragment("", children$1, keyed_children);
  }

  // build/dev/javascript/lustre/lustre/vdom/virtualise.ffi.mjs
  var virtualise = (root2) => {
    const rootMeta = insertMetadataChild(element_kind, null, root2, 0, null);
    const { children } = virtualiseChildren(rootMeta, root2, root2.firstChild);
    if (children.length > 1) {
      const rootNodeMeta = insertMetadataChild(element_kind, null, root2, 0, null);
      rootMeta.kind = fragment_kind;
      rootMeta.node = globalThis.document.createTextNode("");
      rootMeta.parent = rootNodeMeta;
      rootNodeMeta.children.push(rootMeta);
      root2.insertBefore(rootMeta.node, root2.firstChild);
      return fragment3(toList2(children));
    }
    if (children.length === 1) {
      return children[0][1];
    }
    const placeholder = globalThis.document.createTextNode("");
    insertMetadataChild(text_kind, rootMeta, placeholder, 0, null);
    root2.insertBefore(placeholder, root2.firstChild);
    return none2();
  };
  var virtualiseChild = (meta2, domParent, child2, index2) => {
    if (child2.nodeType === COMMENT_NODE) {
      const data = child2.data.trim();
      if (data.startsWith("lustre:fragment")) {
        return virtualiseFragment(meta2, domParent, child2, index2);
      }
      if (data.startsWith("lustre:map")) {
        return virtualiseMap(meta2, domParent, child2, index2);
      }
      if (data.startsWith("lustre:memo")) {
        return virtualiseMemo(meta2, domParent, child2, index2);
      }
      return null;
    }
    if (child2.nodeType === ELEMENT_NODE) {
      return virtualiseElement(meta2, child2, index2);
    }
    if (child2.nodeType === TEXT_NODE) {
      return virtualiseText(meta2, child2, index2);
    }
    return null;
  };
  var virtualiseElement = (metaParent, node, index2) => {
    const key = node.getAttribute("data-lustre-key") ?? "";
    if (key) {
      node.removeAttribute("data-lustre-key");
    }
    const meta2 = insertMetadataChild(element_kind, metaParent, node, index2, key);
    const tag = node.localName;
    const namespace = node.namespaceURI;
    const isHtmlElement = !namespace || namespace === NAMESPACE_HTML;
    if (isHtmlElement && INPUT_ELEMENTS.includes(tag)) {
      virtualiseInputEvents(tag, node);
    }
    const attributes = virtualiseAttributes(node);
    const { children } = virtualiseChildren(meta2, node, node.firstChild);
    const vnode = isHtmlElement ? element3(tag, attributes, toList2(children)) : namespaced2(namespace, tag, attributes, toList2(children));
    return childResult(key, vnode, node.nextSibling);
  };
  var virtualiseChildren = (meta2, domParent, childNode) => {
    const children = [];
    while (childNode && (childNode.nodeType !== COMMENT_NODE || childNode.data.trim() !== "/lustre:fragment")) {
      const child2 = virtualiseChild(meta2, domParent, childNode, children.length);
      if (child2) {
        children.push([child2.key, child2.vnode]);
        childNode = child2.next;
      } else {
        childNode = childNode.nextSibling;
      }
    }
    return { children, end: childNode };
  };
  var virtualiseText = (meta2, node, index2) => {
    insertMetadataChild(text_kind, meta2, node, index2, null);
    return childResult("", text2(node.data), node.nextSibling);
  };
  var virtualiseFragment = (metaParent, domParent, node, index2) => {
    const key = parseKey(node.data);
    const meta2 = insertMetadataChild(fragment_kind, metaParent, node, index2, key);
    const { children, end } = virtualiseChildren(meta2, domParent, node.nextSibling);
    meta2.endNode = end;
    const vnode = fragment3(toList2(children));
    return childResult(key, vnode, end?.nextSibling);
  };
  var virtualiseMap = (metaParent, domParent, node, index2) => {
    const key = parseKey(node.data);
    const meta2 = insertMetadataChild(map_kind, metaParent, node, index2, key);
    const child2 = virtualiseNextChild(meta2, domParent, node, 0);
    if (!child2) return null;
    const vnode = map5(child2.vnode, (x) => x);
    return childResult(key, vnode, child2.next);
  };
  var virtualiseMemo = (meta2, domParent, node, index2) => {
    const key = parseKey(node.data);
    const child2 = virtualiseNextChild(meta2, domParent, node, index2);
    if (!child2) return null;
    domParent.removeChild(node);
    const vnode = memo2(toList2([ref({})]), () => child2.vnode);
    return childResult(key, vnode, child2.next);
  };
  var virtualiseNextChild = (meta2, domParent, node, index2) => {
    while (true) {
      node = node.nextSibling;
      if (!node) return null;
      const child2 = virtualiseChild(meta2, domParent, node, index2);
      if (child2) return child2;
    }
  };
  var childResult = (key, vnode, next) => {
    return { key, vnode, next };
  };
  var virtualiseAttributes = (node) => {
    const attributes = [];
    for (let i = 0; i < node.attributes.length; i++) {
      const attr = node.attributes[i];
      if (attr.name !== "xmlns") {
        attributes.push(attribute2(attr.localName, attr.value));
      }
    }
    return toList2(attributes);
  };
  var INPUT_ELEMENTS = ["input", "select", "textarea"];
  var virtualiseInputEvents = (tag, node) => {
    const value = node.value;
    const checked = node.checked;
    if (tag === "input" && node.type === "checkbox" && !checked) return;
    if (tag === "input" && node.type === "radio" && !checked) return;
    if (node.type !== "checkbox" && node.type !== "radio" && !value) return;
    queueMicrotask(() => {
      node.value = value;
      node.checked = checked;
      node.dispatchEvent(new Event("input", { bubbles: true }));
      node.dispatchEvent(new Event("change", { bubbles: true }));
      if (globalThis.document.activeElement !== node) {
        node.dispatchEvent(new Event("blur", { bubbles: true }));
      }
    });
  };
  var parseKey = (data) => {
    const keyMatch = data.match(/key="([^"]*)"/);
    if (!keyMatch) return "";
    return unescapeKey(keyMatch[1]);
  };
  var unescapeKey = (key) => {
    return key.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&amp;/g, "&").replace(/&#39;/g, "'");
  };
  var toList2 = (arr) => arr.reduceRight((xs, x) => List$NonEmpty(x, xs), empty_list);

  // build/dev/javascript/lustre/lustre/runtime/client/runtime.ffi.mjs
  var is_browser = () => !!globalThis.document;
  var _model, _view, _update, _vdom, _cache, _reconciler, _contexts, _contextSubscriptions, _shouldQueue, _queue, _beforePaint, _afterPaint, _renderTimer, _actions, _Runtime_instances, scheduleRender_fn, handleEffects_fn, handleAsyncEffects_fn, render_fn;
  var Runtime = class {
    constructor(root2, [model, effects], view2, update3, options) {
      __privateAdd(this, _Runtime_instances);
      // PUBLIC API ----------------------------------------------------------------
      __publicField(this, "root", null);
      // PRIVATE API ---------------------------------------------------------------
      __privateAdd(this, _model);
      __privateAdd(this, _view);
      __privateAdd(this, _update);
      __privateAdd(this, _vdom);
      __privateAdd(this, _cache);
      __privateAdd(this, _reconciler);
      __privateAdd(this, _contexts, /* @__PURE__ */ new Map());
      __privateAdd(this, _contextSubscriptions, /* @__PURE__ */ new Map());
      __privateAdd(this, _shouldQueue, false);
      __privateAdd(this, _queue, []);
      __privateAdd(this, _beforePaint, empty_list);
      __privateAdd(this, _afterPaint, empty_list);
      __privateAdd(this, _renderTimer, null);
      __privateAdd(this, _actions, {
        dispatch: (message) => this.dispatch(message),
        emit: (event2, data) => this.emit(event2, data),
        select: () => {
        },
        root: () => this.root,
        provide: (key, value) => this.provide(key, value),
        subscribe: (key, decoder) => this.subscribe(key, decoder),
        unsubscribe: (key) => this.unsubscribe(key)
      });
      this.root = root2;
      __privateSet(this, _model, model);
      __privateSet(this, _view, view2);
      __privateSet(this, _update, update3);
      this.root.addEventListener("context-request", (event2) => {
        if (!(event2.context && event2.callback)) return;
        if (!__privateGet(this, _contexts).has(event2.context)) return;
        event2.stopImmediatePropagation();
        const context = __privateGet(this, _contexts).get(event2.context);
        if (event2.subscribe) {
          const unsubscribe2 = () => {
            context.subscribers = context.subscribers.filter(
              (subscriber) => subscriber !== event2.callback
            );
          };
          context.subscribers.push([event2.callback, unsubscribe2]);
          event2.callback(context.value, unsubscribe2);
        } else {
          event2.callback(context.value);
        }
      });
      const decodeEvent = (event2, path, name) => decode2(__privateGet(this, _cache), path, name, event2);
      const dispatch2 = (event2, data) => {
        const [cache, result] = dispatch(__privateGet(this, _cache), data);
        __privateSet(this, _cache, cache);
        if (Result$isOk(result)) {
          const handler = Result$Ok$0(result);
          if (handler.stop_propagation) event2.stopPropagation();
          if (handler.prevent_default) event2.preventDefault();
          this.dispatch(handler.message, false);
        }
      };
      __privateSet(this, _reconciler, new Reconciler(
        this.root,
        decodeEvent,
        dispatch2,
        options
      ));
      __privateSet(this, _vdom, virtualise(this.root));
      __privateSet(this, _cache, new$4());
      __privateMethod(this, _Runtime_instances, handleEffects_fn).call(this, effects);
      __privateMethod(this, _Runtime_instances, render_fn).call(this);
    }
    dispatch(message, shouldFlush = false) {
      if (__privateGet(this, _shouldQueue)) {
        __privateGet(this, _queue).push(message);
      } else {
        const [model, effects] = __privateGet(this, _update).call(this, __privateGet(this, _model), message);
        __privateSet(this, _model, model);
        __privateMethod(this, _Runtime_instances, scheduleRender_fn).call(this, shouldFlush);
        __privateMethod(this, _Runtime_instances, handleEffects_fn).call(this, effects);
      }
    }
    emit(event2, data) {
      const target = this.root.host ?? this.root;
      target.dispatchEvent(new LustreEvent(event2, data));
    }
    // Provide a context value for any child nodes that request it using the given
    // key. If the key already exists, any existing subscribers will be notified
    // of the change. Otherwise, we store the value and wait for any `context-request`
    // events to come in.
    provide(key, value) {
      if (!__privateGet(this, _contexts).has(key)) {
        __privateGet(this, _contexts).set(key, { value, subscribers: [] });
      } else {
        const context = __privateGet(this, _contexts).get(key);
        if (isEqual2(context.value, value)) {
          return;
        }
        context.value = value;
        for (let i = context.subscribers.length - 1; i >= 0; i--) {
          const [subscriber, unsubscribe2] = context.subscribers[i];
          if (!subscriber) {
            context.subscribers.splice(i, 1);
            continue;
          }
          subscriber(value, unsubscribe2);
        }
      }
    }
    subscribe(key, decoder) {
      if (!key) return;
      __privateGet(this, _contextSubscriptions).get(key)?.();
      const target = this.root.host ?? this.root;
      target.dispatchEvent(
        new ContextRequestEvent(
          key,
          (value, unsubscribe2) => {
            const previousUnsubscribe = __privateGet(this, _contextSubscriptions).get(key);
            if (previousUnsubscribe !== unsubscribe2) {
              previousUnsubscribe?.();
            }
            const decoded = run(value, decoder);
            __privateGet(this, _contextSubscriptions).set(key, unsubscribe2);
            if (Result$isOk(decoded)) {
              this.dispatch(Result$Ok$0(decoded), true);
            }
          },
          true
        )
      );
    }
    unsubscribe(key) {
      const unsubscribe2 = __privateGet(this, _contextSubscriptions).get(key);
      if (unsubscribe2) {
        unsubscribe2();
        __privateGet(this, _contextSubscriptions).delete(key);
      }
    }
    unsubscribeAll() {
      for (const [_, unsubscribe2] of __privateGet(this, _contextSubscriptions)) {
        unsubscribe2?.();
      }
      __privateGet(this, _contextSubscriptions).clear();
    }
  };
  _model = new WeakMap();
  _view = new WeakMap();
  _update = new WeakMap();
  _vdom = new WeakMap();
  _cache = new WeakMap();
  _reconciler = new WeakMap();
  _contexts = new WeakMap();
  _contextSubscriptions = new WeakMap();
  _shouldQueue = new WeakMap();
  _queue = new WeakMap();
  _beforePaint = new WeakMap();
  _afterPaint = new WeakMap();
  _renderTimer = new WeakMap();
  _actions = new WeakMap();
  _Runtime_instances = new WeakSet();
  scheduleRender_fn = function(shouldFlush = false) {
    if (__privateGet(this, _renderTimer)) return;
    if (shouldFlush) {
      __privateSet(this, _renderTimer, "sync");
      queueMicrotask(() => __privateMethod(this, _Runtime_instances, render_fn).call(this));
    } else {
      __privateSet(this, _renderTimer, window.requestAnimationFrame(() => __privateMethod(this, _Runtime_instances, render_fn).call(this)));
    }
  };
  // #handleEffects processes all effects, without scheduling a render.
  handleEffects_fn = function(effects) {
    __privateSet(this, _shouldQueue, true);
    let updateCalledDuringEffects = false;
    while (true) {
      iterate(effects.synchronous, (effect) => effect(__privateGet(this, _actions)));
      __privateSet(this, _beforePaint, append4(__privateGet(this, _beforePaint), effects.before_paint));
      __privateSet(this, _afterPaint, append4(__privateGet(this, _afterPaint), effects.after_paint));
      if (!__privateGet(this, _queue).length) break;
      const message = __privateGet(this, _queue).shift();
      [__privateWrapper(this, _model)._, effects] = __privateGet(this, _update).call(this, __privateGet(this, _model), message);
      updateCalledDuringEffects = true;
    }
    __privateSet(this, _shouldQueue, false);
    return updateCalledDuringEffects;
  };
  // Async effects (before_paint and after_paint) can trigger without causing a
  // new model update. Here we process these effects and schedules the next
  // (synchronous) frame if required.
  handleAsyncEffects_fn = function(effects) {
    if (__privateMethod(this, _Runtime_instances, handleEffects_fn).call(this, effects)) {
      __privateMethod(this, _Runtime_instances, scheduleRender_fn).call(this, true);
    }
  };
  render_fn = function() {
    __privateSet(this, _renderTimer, null);
    const next = __privateGet(this, _view).call(this, __privateGet(this, _model));
    const { patch, cache } = diff(__privateGet(this, _cache), __privateGet(this, _vdom), next);
    __privateSet(this, _cache, cache);
    __privateSet(this, _vdom, next);
    __privateGet(this, _reconciler).push(patch, memos(cache));
    if (List$isNonEmpty(__privateGet(this, _beforePaint))) {
      const effects = makeEffect(__privateGet(this, _beforePaint));
      __privateSet(this, _beforePaint, empty_list);
      queueMicrotask(() => __privateMethod(this, _Runtime_instances, handleAsyncEffects_fn).call(this, effects));
    }
    if (List$isNonEmpty(__privateGet(this, _afterPaint))) {
      const effects = makeEffect(__privateGet(this, _afterPaint));
      __privateSet(this, _afterPaint, empty_list);
      window.requestAnimationFrame(() => __privateMethod(this, _Runtime_instances, handleAsyncEffects_fn).call(this, effects));
    }
  };
  function makeEffect(synchronous) {
    return {
      synchronous,
      after_paint: empty_list,
      before_paint: empty_list
    };
  }
  var ContextRequestEvent = class extends Event {
    constructor(context, callback, subscribe2) {
      super("context-request", { bubbles: true, composed: true });
      this.context = context;
      this.callback = callback;
      this.subscribe = subscribe2;
    }
  };
  var LustreEvent = class extends CustomEvent {
    constructor(name, detail) {
      super(name, { detail, bubbles: true, composed: true });
      // We can't rely on `instanceof` checks because the server component client
      // runtime is bundled on its own and thus will have its own copy of this class.
      __publicField(this, "isLustreEvent", true);
    }
  };

  // build/dev/javascript/lustre/lustre/runtime/client/spa.ffi.mjs
  var _runtime;
  var Spa = class {
    constructor(root2, [init2, effects], update3, view2) {
      __privateAdd(this, _runtime);
      __privateSet(this, _runtime, new Runtime(root2, [init2, effects], view2, update3));
    }
    send(message) {
      if (Message$isEffectDispatchedMessage(message)) {
        this.dispatch(message.message, false);
      } else if (Message$isEffectEmitEvent(message)) {
        this.emit(message.name, message.data);
      } else if (Message$isSystemRequestedShutdown(message)) {
      }
    }
    dispatch(message) {
      __privateGet(this, _runtime).dispatch(message);
    }
    emit(event2, data) {
      __privateGet(this, _runtime).emit(event2, data);
    }
  };
  _runtime = new WeakMap();
  var start = ({ init: init2, update: update3, view: view2 }, selector, flags) => {
    if (!is_browser()) return Result$Error(Error$NotABrowser());
    const root2 = selector instanceof HTMLElement ? selector : globalThis.document.querySelector(selector);
    if (!root2) return Result$Error(Error$ElementNotFound(selector));
    return Result$Ok(new Spa(root2, init2(flags), update3, view2));
  };

  // build/dev/javascript/lustre/lustre.mjs
  var ElementNotFound = class extends CustomType {
    constructor(selector) {
      super();
      this.selector = selector;
    }
  };
  var Error$ElementNotFound = (selector) => new ElementNotFound(selector);
  var NotABrowser = class extends CustomType {
  };
  var Error$NotABrowser$const = new NotABrowser();
  var Error$NotABrowser = () => Error$NotABrowser$const;
  function application(init2, update3, view2) {
    return new App(
      Option$None$const,
      init2,
      update3,
      view2,
      default_config
    );
  }
  function start4(app, selector, arguments$) {
    return guard(
      !is_browser(),
      new Error2(Error$NotABrowser$const),
      () => {
        return start(app, selector, arguments$);
      }
    );
  }

  // build/dev/javascript/fizzlayer_web/status_ffi.mjs
  async function read(path) {
    const response = await fetch(path, { cache: "no-store" });
    const data = await response.json().catch(() => ({}));
    if (!response.ok) {
      const message = data.error && data.error.message;
      throw new Error(message || "The check failed.");
    }
    return data;
  }
  function text3(value) {
    if (typeof value !== "string" || value === "") return "";
    return value;
  }
  function load(deliver) {
    const run2 = async () => {
      let apiFailed = false;
      let status = "";
      let database = "";
      try {
        const data = await read("/api/status");
        status = text3(data.status);
        database = text3(data.database);
      } catch {
        apiFailed = true;
      }
      let streamFailed = false;
      let enabled = false;
      try {
        const data = await read("/api/stream");
        enabled = data.enabled === true;
      } catch {
        streamFailed = true;
      }
      deliver(apiFailed, status, database, streamFailed, enabled, (/* @__PURE__ */ new Date()).toLocaleString());
    };
    void run2();
  }

  // build/dev/javascript/fizzlayer_web/status.mjs
  var Operational = class extends CustomType {
  };
  var Health$Operational$const = new Operational();
  var Degraded = class extends CustomType {
  };
  var Health$Degraded$const = new Degraded();
  var Unavailable = class extends CustomType {
  };
  var Health$Unavailable$const = new Unavailable();
  var Unreported = class extends CustomType {
  };
  var Health$Unreported$const = new Unreported();
  var Row = class extends CustomType {
    constructor(name, health, detail) {
      super();
      this.name = name;
      this.health = health;
      this.detail = detail;
    }
  };
  var Checking = class extends CustomType {
  };
  var Phase$Checking$const = new Checking();
  var Reported = class extends CustomType {
    constructor(rows, checked) {
      super();
      this.rows = rows;
      this.checked = checked;
    }
  };
  var Loaded = class extends CustomType {
    constructor(api_failed, status, database, stream_failed, enabled, when) {
      super();
      this.api_failed = api_failed;
      this.status = status;
      this.database = database;
      this.stream_failed = stream_failed;
      this.enabled = enabled;
      this.when = when;
    }
  };
  function database_detail(database) {
    if (database === "connected") {
      return "The API and its database responded.";
    } else if (database === "") {
      return "Database: unknown.";
    } else {
      let other = database;
      return "Database: " + other + ".";
    }
  }
  function api_row(failed, status, database) {
    if (failed) {
      return new Row(
        "API",
        Health$Unavailable$const,
        "The status check did not answer."
      );
    } else {
      let $ = status === "ok";
      if ($) {
        return new Row("API", Health$Operational$const, database_detail(database));
      } else {
        return new Row("API", Health$Degraded$const, database_detail(database));
      }
    }
  }
  function scheduler_row() {
    return new Row(
      "Alert scheduler",
      Health$Unreported$const,
      "The public status check does not include silence scans or queued calls."
    );
  }
  function stream_row(failed, enabled) {
    if (failed) {
      return new Row(
        "Live streaming",
        Health$Unavailable$const,
        "The stream check did not answer."
      );
    } else {
      if (enabled) {
        return new Row(
          "Live streaming",
          Health$Operational$const,
          "WebSocket and MQTT-over-WebSocket addresses are available."
        );
      } else {
        return new Row(
          "Live streaming",
          Health$Degraded$const,
          "Live streaming is not configured."
        );
      }
    }
  }
  function report_rows(api_failed, status, database, stream_failed, enabled) {
    return prepend(
      api_row(api_failed, status, database),
      prepend(
        scheduler_row(),
        prepend(stream_row(stream_failed, enabled), List$Empty$const)
      )
    );
  }
  function checked_line(when) {
    return "Checked just now from this browser (" + when + "). This page does not keep an uptime history or state an SLA.";
  }
  function health_name(health) {
    if (health instanceof Operational) {
      return "operational";
    } else if (health instanceof Degraded) {
      return "degraded";
    } else if (health instanceof Unavailable) {
      return "unavailable";
    } else {
      return "unreported";
    }
  }
  function health_label(health) {
    if (health instanceof Operational) {
      return "Operational";
    } else if (health instanceof Degraded) {
      return "Degraded";
    } else if (health instanceof Unavailable) {
      return "Unavailable";
    } else {
      return "Not reported";
    }
  }
  function load_reports() {
    return from2(
      (dispatch2) => {
        return load(
          (api_failed, status, database, stream_failed, enabled, when) => {
            return dispatch2(
              new Loaded(
                api_failed,
                status,
                database,
                stream_failed,
                enabled,
                when
              )
            );
          }
        );
      }
    );
  }
  function init(_) {
    return [Phase$Checking$const, load_reports()];
  }
  function update2(_, message) {
    let api_failed = message.api_failed;
    let status = message.status;
    let database = message.database;
    let stream_failed = message.stream_failed;
    let enabled = message.enabled;
    let when = message.when;
    return [
      new Reported(
        report_rows(api_failed, status, database, stream_failed, enabled),
        checked_line(when)
      ),
      none()
    ];
  }
  function reported_item(row) {
    return li(
      List$Empty$const,
      prepend(
        div(
          List$Empty$const,
          prepend(
            strong(
              List$Empty$const,
              prepend(text2(row.name), List$Empty$const)
            ),
            prepend(
              p(
                List$Empty$const,
                prepend(text2(row.detail), List$Empty$const)
              ),
              List$Empty$const
            )
          )
        ),
        prepend(
          span(
            prepend(
              class$("status-state"),
              prepend(
                attribute2("data-state", health_name(row.health)),
                List$Empty$const
              )
            ),
            prepend(
              text2(health_label(row.health)),
              List$Empty$const
            )
          ),
          List$Empty$const
        )
      )
    );
  }
  function checking_item() {
    return li(
      List$Empty$const,
      prepend(
        div(
          List$Empty$const,
          prepend(
            strong(
              List$Empty$const,
              prepend(text2("Checking"), List$Empty$const)
            ),
            prepend(
              p(
                List$Empty$const,
                prepend(
                  text2("Asking /api/status and /api/stream."),
                  List$Empty$const
                )
              ),
              List$Empty$const
            )
          )
        ),
        List$Empty$const
      )
    );
  }
  function view(phase) {
    return fragment2(
      prepend(
        ul(
          prepend(
            class$("status-list"),
            prepend(id("status-list"), List$Empty$const)
          ),
          (() => {
            if (phase instanceof Checking) {
              return prepend(checking_item(), List$Empty$const);
            } else {
              let rows = phase.rows;
              return map2(rows, reported_item);
            }
          })()
        ),
        prepend(
          p(
            prepend(
              class$("status-checked"),
              prepend(
                id("status-checked"),
                prepend(role("status"), List$Empty$const)
              )
            ),
            prepend(
              text2(
                (() => {
                  if (phase instanceof Checking) {
                    return "";
                  } else {
                    let checked = phase.checked;
                    return checked;
                  }
                })()
              ),
              List$Empty$const
            )
          ),
          List$Empty$const
        )
      )
    );
  }
  function install() {
    let app = application(init, update2, view);
    let $ = start4(app, "#status-app", void 0);
    if ($ instanceof Ok) {
      return void 0;
    } else {
      return void 0;
    }
  }

  // entries/status.js
  install();
})();
