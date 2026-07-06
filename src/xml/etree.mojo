"""An ElementTree-shaped DOM API built on top of the XML pull parser.

`fromstring(text)` parses a full document into a tree of `Element`s;
`tostring(elem)` serializes a tree back to XML text. The text/tail model
mirrors Python's `xml.etree.ElementTree`:

  - `Element.text` is the character data directly after the start tag and
    before the first child element.
  - `Element.tail` is the character data after this element's *end* tag and
    before the next sibling's start tag.

So for `<a>t0<b/>t1<c/>t2</a>`: `a.text == "t0"`, `b.tail == "t1"`,
`c.tail == "t2"`, and `a.tail == ""`.

Parsing is strict about well-formedness (mismatched/stray end tags,
unclosed elements, undefined entities all raise), matching ElementTree's
behavior rather than the liberal recovery the raw pull parser offers.

## Path support (find / findall / findtext)

A pragmatic subset of ElementTree paths, not full XPath:

  - `tag`         — direct children named `tag`
  - `a/b/c`       — a chain of direct-child steps
  - `*`           — a single-level wildcard (matches any one child)
  - `.//tag`      — `tag` at any depth in the subtree (descendant search;
                    a following path like `.//a/b` matches child `b` of
                    every descendant `a`)
  - `{uri}local`  — Clark-notation namespaced tags match by exact string
  - a leading `./` is accepted and ignored; `.` alone selects the element
    itself

## Namespaces

Prefixes resolve to Clark notation: `<a:foo xmlns:a="http://x">` yields the
tag `{http://x}foo`. `xmlns`/`xmlns:*` declarations are collected lexically
as the parser descends and popped as elements close, so nested redefinition
is honored (this is proper scoped resolution, not the flat document-scoped
approach the feed parser uses). A default namespace (`xmlns="..."`) applies
to unprefixed *element* names but never to unprefixed *attribute* names, per
the XML namespaces spec. `xmlns` declarations are consumed for resolution
and are not retained in `Element.attrib`. The reserved `xml` prefix is
implicitly bound to `http://www.w3.org/XML/1998/namespace`, so `xml:lang`
resolves to `{http://www.w3.org/XML/1998/namespace}lang` (and serializes
back to `xml:lang` without a redundant declaration).

## Serialization & namespaces

`tostring` collects every distinct namespace URI in the tree, assigns each a
generated prefix (`ns0`, `ns1`, ...), declares them all on the root start
tag, and qualifies namespaced tags/attributes with those prefixes. The
output is well-formed and round-trips: `fromstring(tostring(e))` yields a
structurally-equal tree (element/attribute *order* within a start tag
follows `Dict` insertion order and is not otherwise guaranteed).
"""

from xml.pull import (
    XmlPullParser,
    XmlEvent,
    EVENT_START,
    EVENT_END,
    EVENT_TEXT,
    EVENT_EOF,
)


# Maximum element nesting `fromstring` will build. Real documents nest a few
# dozen levels deep at most; a hostile input can chain elements thousands deep
# to force the tree-walking APIs (which return owned copies) into quadratic
# time. Rejecting pathological depth turns that denial-of-service into a clean
# error. Generous enough to never reject real XML.
comptime MAX_DEPTH = 512


# The `xml` prefix is reserved and implicitly bound to this URI (Namespaces in
# XML §3). It needs no declaration; ElementTree resolves `xml:lang` to
# `{http://www.w3.org/XML/1998/namespace}lang`, and serializes that URI back to
# the `xml:` prefix (never redeclaring it, which the spec forbids).
comptime _XML_NS = "http://www.w3.org/XML/1998/namespace"


# --------------------------------------------------------------------------
# Small string helpers (Mojo String has no slice syntax; work over bytes).
# --------------------------------------------------------------------------


def _substr(s: String, start: Int, end: Int) -> String:
    return String(StringSlice(unsafe_from_utf8=s.as_bytes()[start:end]))


def _colon_index(name: String) -> Int:
    """Byte offset of the first ':' in `name`, or -1."""
    var bytes = name.as_bytes()
    for i in range(len(bytes)):
        if bytes[i] == UInt8(ord(":")):
            return i
    return -1


def _find_byte(s: String, target: Int) -> Int:
    var bytes = s.as_bytes()
    for i in range(len(bytes)):
        if bytes[i] == UInt8(target):
            return i
    return -1


def _is_all_whitespace(s: String) -> Bool:
    """True if `s` is empty or only XML whitespace (space, tab, CR, LF)."""
    var bytes = s.as_bytes()
    for i in range(len(bytes)):
        var b = bytes[i]
        if b != 0x20 and b != 0x09 and b != 0x0D and b != 0x0A:
            return False
    return True


# --------------------------------------------------------------------------
# The Element type.
# --------------------------------------------------------------------------


struct Element(Copyable, Movable, Sized, Writable):
    """A single XML element: tag, attributes, text/tail, and children."""

    var tag: String
    var attrib: Dict[String, String]
    var text: String
    var tail: String
    var children: List[Element]

    def __init__(out self, var tag: String):
        self.tag = tag^
        self.attrib = Dict[String, String]()
        self.text = String()
        self.tail = String()
        self.children = List[Element]()

    def __del__(deinit self):
        # An explicit (field-destroying) destructor breaks the
        # implicit-deletability inference cycle that a directly recursive
        # `List[Element]` field would otherwise trip.
        pass

    def __init__(out self, var tag: String, var attrib: Dict[String, String]):
        self.tag = tag^
        self.attrib = attrib^
        self.text = String()
        self.tail = String()
        self.children = List[Element]()

    def write_to(self, mut writer: Some[Writer]):
        # A compact, non-raising summary for print()/debugging.
        writer.write("<Element '", self.tag, "' children=")
        writer.write(len(self.children), ">")

    # -- attribute access --------------------------------------------------

    def get(self, key: String, default: String = "") -> String:
        """Attribute value for `key`, or `default` when absent."""
        return self.attrib.get(key, default.copy())

    def set(mut self, key: String, value: String):
        """Set attribute `key` to `value`."""
        self.attrib[key] = value.copy()

    # -- children ----------------------------------------------------------

    def append(mut self, var child: Element):
        """Append `child` as the last child of this element."""
        self.children.append(child^)

    def __len__(self) -> Int:
        """Number of direct children."""
        return len(self.children)

    # -- searching ---------------------------------------------------------

    def findall(self, path: String) -> List[Element]:
        """All elements matching `path` (see module docstring for grammar).

        Returns copies; an empty list when nothing matches. Never raises.
        """
        var result = List[Element]()
        if path == ".":
            result.append(self.copy())
            return result^
        var p = path.copy()
        var descendant = False
        if p.startswith(".//"):
            descendant = True
            p = _substr(p, 3, p.byte_length())
        elif p.startswith("./"):
            p = _substr(p, 2, p.byte_length())
        var steps = _split_path(p)
        if len(steps) == 0:
            return result^
        if descendant:
            _match_descendant(self, steps, result)
        else:
            _collect(self, steps, 0, result)
        return result^

    def find(self, path: String) raises -> Element:
        """First element matching `path`; raises if there is no match.

        Callers that prefer a non-raising API can use `find_opt`, which
        returns an `Optional[Element]`.
        """
        var matches = self.findall(path)
        if len(matches) == 0:
            raise Error("mojo-xml: no element matches path: " + path)
        return matches[0].copy()

    def find_opt(self, path: String) -> Optional[Element]:
        """The first element matching `path`, or `None`.

        This is the non-raising companion to `find`. (The spec sketched a
        `(Bool, Element)` tuple, but Mojo's variadic tuple init rejects a
        heterogeneous tuple containing `Element` — a type with a custom
        destructor — so `Optional[Element]` is the idiomatic equivalent:
        test it with `if result:` and read it with `result.value()`.)
        """
        var matches = self.findall(path)
        if len(matches) == 0:
            return None
        return Optional(matches[0].copy())

    def findtext(self, path: String, default: String = "") -> String:
        """`.text` of the first element matching `path`, else `default`."""
        var matches = self.findall(path)
        if len(matches) == 0:
            return default.copy()
        return matches[0].text.copy()

    def iter(self, tag: String = "") -> List[Element]:
        """Depth-first list of this element and its descendants.

        With a non-empty `tag`, only elements whose tag equals `tag` are
        returned; an empty `tag` returns every element (self included).
        """
        var out = List[Element]()
        _iter_collect(self, tag, out)
        return out^


# --------------------------------------------------------------------------
# Path matching helpers (free functions; recursion over borrowed Elements).
# --------------------------------------------------------------------------


def _split_path(path: String) -> List[String]:
    """Split a path on '/', but not inside `{...}` Clark-notation URIs.

    Empty segments (from leading/trailing/double slashes) are dropped.
    """
    var out = List[String]()
    var bytes = path.as_bytes()
    var start = 0
    var depth = 0
    for i in range(len(bytes)):
        var b = bytes[i]
        if b == UInt8(ord("{")):
            depth += 1
        elif b == UInt8(ord("}")):
            if depth > 0:
                depth -= 1
        elif b == UInt8(ord("/")) and depth == 0:
            if i > start:
                out.append(_substr(path, start, i))
            start = i + 1
    if len(bytes) > start:
        out.append(_substr(path, start, len(bytes)))
    return out^


def _collect(elem: Element, steps: List[String], i: Int, mut out: List[Element]):
    """Match `steps[i:]` as a chain of direct-child navigations."""
    if i >= len(steps):
        out.append(elem.copy())
        return
    ref step = steps[i]
    for ref child in elem.children:
        if step == "*" or child.tag == step:
            _collect(child, steps, i + 1, out)


def _match_descendant(
    elem: Element, steps: List[String], mut out: List[Element]
):
    """Match `steps[0]` against any descendant, then `steps[1:]` as
    direct children of each such match."""
    for ref child in elem.children:
        if steps[0] == "*" or child.tag == steps[0]:
            _collect(child, steps, 1, out)
        # Recursing into a leaf can match nothing, so guard on it — this
        # also keeps the call conditional (silences a spurious
        # infinite-recursion warning the compiler emits otherwise).
        if len(child.children) != 0:
            _match_descendant(child, steps, out)


def _iter_collect(elem: Element, tag: String, mut out: List[Element]):
    if tag.byte_length() == 0 or elem.tag == tag:
        out.append(elem.copy())
    # Recurse through a helper (mutual, not direct self-recursion) so the
    # compiler's infinite-recursion heuristic stays quiet.
    _iter_children(elem, tag, out)


def _iter_children(elem: Element, tag: String, mut out: List[Element]):
    for ref child in elem.children:
        _iter_collect(child, tag, out)


# --------------------------------------------------------------------------
# Namespace resolution (scoped: a stack of prefix->URI declaration frames).
# --------------------------------------------------------------------------


def _lookup_prefix(
    ns_frames: List[Dict[String, String]], prefix: String
) raises -> String:
    """Innermost binding for `prefix`, or "" if unbound.

    An `xmlns=""` binding (undeclaring the default namespace) reads back as
    "", which callers treat as "no namespace" — the correct behavior.
    """
    for i in range(len(ns_frames) - 1, -1, -1):
        if prefix in ns_frames[i]:
            return ns_frames[i][prefix].copy()
    return String()


def _resolve_tag(
    name: String, ns_frames: List[Dict[String, String]]
) raises -> String:
    """Element name -> Clark notation, applying the default namespace to
    unprefixed names."""
    var colon = _colon_index(name)
    if colon > 0:
        var prefix = _substr(name, 0, colon)
        var uri = _lookup_prefix(ns_frames, prefix)
        if uri.byte_length() > 0:
            return "{" + uri + "}" + _substr(name, colon + 1, name.byte_length())
        if prefix == "xml":
            # The `xml` prefix is reserved and implicitly bound; resolve it to
            # the reserved URI in Clark notation, matching ElementTree.
            return "{" + String(_XML_NS) + "}" + _substr(
                name, colon + 1, name.byte_length()
            )
        raise Error("mojo-xml: unbound namespace prefix '" + prefix + "'")
    var default_uri = _lookup_prefix(ns_frames, String())
    if default_uri.byte_length() > 0:
        return "{" + default_uri + "}" + name
    return name.copy()


def _resolve_attr(
    name: String, ns_frames: List[Dict[String, String]]
) raises -> String:
    """Attribute name -> Clark notation. The default namespace never
    applies to unprefixed attributes."""
    var colon = _colon_index(name)
    if colon > 0:
        var prefix = _substr(name, 0, colon)
        var uri = _lookup_prefix(ns_frames, prefix)
        if uri.byte_length() > 0:
            return "{" + uri + "}" + _substr(name, colon + 1, name.byte_length())
        if prefix == "xml":
            # Reserved prefix -> reserved URI in Clark notation (ElementTree).
            return "{" + String(_XML_NS) + "}" + _substr(
                name, colon + 1, name.byte_length()
            )
        raise Error("mojo-xml: unbound namespace prefix '" + prefix + "'")
    return name.copy()


# --------------------------------------------------------------------------
# Parsing: events -> tree, tracking text/tail via an open-element stack.
# --------------------------------------------------------------------------


def _flush_text(mut stack: List[Element], mut text_buf: String):
    """Assign accumulated character data to the right slot per the ET model.

    Text goes to the open element's `.text` when it has no children yet,
    otherwise to the `.tail` of its most recently closed child.
    """
    if text_buf.byte_length() == 0:
        return
    if len(stack) == 0:
        text_buf = String()  # text outside the root element: discard
        return
    var top = len(stack) - 1
    if len(stack[top].children) == 0:
        stack[top].text += text_buf
    else:
        var last = len(stack[top].children) - 1
        stack[top].children[last].tail += text_buf
    text_buf = String()


def fromstring(var text: String) raises -> Element:
    """Parse a full XML document string into its root `Element`.

    Raises on malformed input (mismatched or stray end tags, elements left
    open at end of input, undefined entities) and on documents with no root
    element.
    """
    var parser = XmlPullParser(text^, strict=True)
    var stack = List[Element]()
    var ns_frames = List[Dict[String, String]]()
    var text_buf = String()
    var root = Element(String())
    var got_root = False

    while True:
        var event = parser.next_event()
        if event.kind == EVENT_EOF:
            break

        if event.kind == EVENT_START:
            if got_root:
                # A well-formed XML document has exactly one root element;
                # anything after it closes is junk. ElementTree raises here.
                raise Error(
                    "mojo-xml: junk after document element (multiple roots)"
                )
            if len(stack) >= MAX_DEPTH:
                raise Error(
                    "mojo-xml: element nesting exceeds "
                    + String(MAX_DEPTH)
                    + " levels"
                )
            _flush_text(stack, text_buf)
            # Collect this element's own namespace declarations first, so
            # they are in scope for its own name and attribute resolution.
            var decl = Dict[String, String]()
            for entry in event.attrs.items():
                if entry.key == "xmlns":
                    decl[String()] = entry.value.copy()
                elif entry.key.startswith("xmlns:"):
                    var prefix = _substr(entry.key, 6, entry.key.byte_length())
                    decl[prefix] = entry.value.copy()
            ns_frames.append(decl^)

            var tag = _resolve_tag(event.name, ns_frames)
            var attrib = Dict[String, String]()
            for entry in event.attrs.items():
                if entry.key == "xmlns" or entry.key.startswith("xmlns:"):
                    continue
                attrib[_resolve_attr(entry.key, ns_frames)] = entry.value.copy()
            stack.append(Element(tag^, attrib^))

        elif event.kind == EVENT_TEXT:
            if len(stack) == 0:
                # Character data outside the root element. Whitespace is
                # allowed (and ignored); anything else is junk, like leading
                # "foo<a/>" or trailing "<a/>bar" — ElementTree raises.
                if not _is_all_whitespace(event.text):
                    raise Error(
                        "mojo-xml: text outside the document element"
                    )
            else:
                text_buf += event.text

        elif event.kind == EVENT_END:
            _flush_text(stack, text_buf)
            if len(stack) == 0:
                continue  # defensive: strict parser prevents this
            var elem = stack.pop()
            if len(ns_frames) > 0:
                _ = ns_frames.pop()
            if len(stack) == 0:
                root = elem^
                got_root = True
            else:
                var top = len(stack) - 1
                stack[top].children.append(elem^)

    if not got_root:
        raise Error("mojo-xml: no root element found")
    return root^


# --------------------------------------------------------------------------
# Serialization: tree -> XML text.
# --------------------------------------------------------------------------


def _escape(s: String, in_attr: Bool) -> String:
    """Escape `&`, `<`, `>` in text; additionally `\"` and the whitespace
    controls tab/LF/CR in attribute values (so a newline in an attribute
    survives a round trip, matching CPython's `_escape_attrib`). Non-ASCII
    bytes are copied through untouched (output stays UTF-8)."""
    var out = String()
    var bytes = s.as_bytes()
    var run_start = 0
    for i in range(len(bytes)):
        var b = bytes[i]
        var repl: String
        if b == UInt8(ord("&")):
            repl = String("&amp;")
        elif b == UInt8(ord("<")):
            repl = String("&lt;")
        elif b == UInt8(ord(">")):
            repl = String("&gt;")
        elif in_attr and b == UInt8(ord('"')):
            repl = String("&quot;")
        elif in_attr and b == 0x09:
            repl = String("&#09;")
        elif in_attr and b == 0x0A:
            repl = String("&#10;")
        elif in_attr and b == 0x0D:
            repl = String("&#13;")
        else:
            continue
        if i > run_start:
            out += _substr(s, run_start, i)
        out += repl
        run_start = i + 1
    if len(bytes) > run_start:
        out += _substr(s, run_start, len(bytes))
    return out^


def _maybe_add_uri(name: String, mut uris: List[String]):
    if not name.startswith("{"):
        return
    var close = _find_byte(name, ord("}"))
    if close == -1:
        return
    var uri = _substr(name, 1, close)
    for i in range(len(uris)):
        if uris[i] == uri:
            return
    uris.append(uri^)


def _collect_uris(elem: Element, mut uris: List[String]):
    _maybe_add_uri(elem.tag, uris)
    for entry in elem.attrib.items():
        _maybe_add_uri(entry.key, uris)
    # Recurse through a helper (mutual, not direct self-recursion) so the
    # compiler's infinite-recursion heuristic stays quiet.
    _collect_uris_children(elem, uris)


def _collect_uris_children(elem: Element, mut uris: List[String]):
    for ref child in elem.children:
        _collect_uris(child, uris)


def _qualify(name: String, ns: Dict[String, String]) raises -> String:
    """Render a possibly-Clark-notation name using the prefix map."""
    if not name.startswith("{"):
        return name.copy()
    var close = _find_byte(name, ord("}"))
    if close == -1:
        return name.copy()
    var uri = _substr(name, 1, close)
    var local = _substr(name, close + 1, name.byte_length())
    if uri in ns:
        return ns[uri] + ":" + local
    return local^


def _write_elem(
    elem: Element, ns: Dict[String, String], is_root: Bool, mut out: String
) raises:
    out += "<"
    out += _qualify(elem.tag, ns)
    if is_root:
        for entry in ns.items():
            # The reserved xml namespace is predefined and must never be
            # declared (Namespaces in XML §3), so skip it here.
            if entry.key == _XML_NS:
                continue
            out += " xmlns:" + entry.value + '="'
            out += _escape(entry.key, True) + '"'
    for entry in elem.attrib.items():
        out += " " + _qualify(entry.key, ns) + '="'
        out += _escape(entry.value, True) + '"'
    if len(elem.children) == 0 and elem.text.byte_length() == 0:
        out += " />"
        return
    out += ">"
    out += _escape(elem.text, False)
    for ref child in elem.children:
        _write_elem(child, ns, False, out)
        out += _escape(child.tail, False)
    out += "</"
    out += _qualify(elem.tag, ns)
    out += ">"


def tostring(elem: Element) raises -> String:
    """Serialize `elem` (and its subtree) to XML text.

    Text content escapes `&<>`; attribute values additionally escape `\"`.
    Namespace URIs are declared on the root with generated `nsN` prefixes.
    """
    var uris = List[String]()
    _collect_uris(elem, uris)
    var ns = Dict[String, String]()
    var idx = 0
    for i in range(len(uris)):
        if uris[i] == _XML_NS:
            # Bind the reserved URI back to its fixed `xml` prefix.
            ns[uris[i]] = String("xml")
        else:
            ns[uris[i]] = String("ns") + String(idx)
            idx += 1
    var out = String()
    _write_elem(elem, ns, True, out)
    return out^


def SubElement(mut parent: Element, var tag: String) -> Element:
    """Create an element named `tag`, append it to `parent`, and return a
    *copy* of it.

    Borrow-model caveat: Mojo cannot hand back a live mutable reference into
    `parent.children`, so the returned Element is a snapshot. To build a
    child with attributes/text/children, construct it fully and then call
    `parent.append(child^)`; use `SubElement` only when a detached copy is
    acceptable (e.g. immediately inspecting the freshly added empty child).
    """
    parent.children.append(Element(tag^))
    return parent.children[len(parent.children) - 1].copy()
