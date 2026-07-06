"""Minimal non-validating XML pull parser.

Emits a flat stream of events (start element, end element, text) from a
UTF-8 XML document held in memory. Designed for feed parsing: namespaces
are not resolved (prefixes stay part of the element name, e.g.
"itunes:duration"), DTDs are skipped, and the five predefined entities
plus numeric character references are decoded in text and attributes.
"""

comptime EVENT_START = 0
comptime EVENT_END = 1
comptime EVENT_TEXT = 2
comptime EVENT_EOF = 3

comptime _LT = UInt8(ord("<"))
comptime _GT = UInt8(ord(">"))
comptime _AMP = UInt8(ord("&"))
comptime _SLASH = UInt8(ord("/"))
comptime _BANG = UInt8(ord("!"))
comptime _QUESTION = UInt8(ord("?"))
comptime _EQUALS = UInt8(ord("="))
comptime _SQUOTE = UInt8(ord("'"))
comptime _DQUOTE = UInt8(ord('"'))
comptime _SEMI = UInt8(ord(";"))
comptime _HASH = UInt8(ord("#"))
comptime _LBRACKET = UInt8(ord("["))
comptime _RBRACKET = UInt8(ord("]"))


def _is_space(b: UInt8) -> Bool:
    return b == 0x20 or b == 0x09 or b == 0x0A or b == 0x0D


def _append_codepoint(mut out: String, cp_in: Int):
    """UTF-8 encode a Unicode scalar value and append it to `out`.

    Out-of-range and surrogate codepoints become U+FFFD (replacement
    character) rather than producing invalid UTF-8.
    """
    var cp = cp_in
    if cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF):
        cp = 0xFFFD
    var buf = List[UInt8]()
    if cp < 0x80:
        buf.append(UInt8(cp))
    elif cp < 0x800:
        buf.append(UInt8(0xC0 | (cp >> 6)))
        buf.append(UInt8(0x80 | (cp & 0x3F)))
    elif cp < 0x10000:
        buf.append(UInt8(0xE0 | (cp >> 12)))
        buf.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        buf.append(UInt8(0x80 | (cp & 0x3F)))
    else:
        buf.append(UInt8(0xF0 | (cp >> 18)))
        buf.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
        buf.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        buf.append(UInt8(0x80 | (cp & 0x3F)))
    out += String(StringSlice(unsafe_from_utf8=Span(buf)))


def _cp1252_codepoint(b: UInt8) -> Int:
    """Map a Windows-1252 byte to its Unicode codepoint.

    Identity for everything except 0x80–0x9F, where Windows-1252 differs
    from Latin-1. Treating declared Latin-1 as CP1252 matches browser
    behavior (the C1 range is unused control codes in real Latin-1 text).
    """
    var c = Int(b)
    if c < 0x80 or c > 0x9F:
        return c
    var table: List[Int] = [
        0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F,
        0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
    ]
    return table[c - 0x80]


def _transcode_latin(source: String) -> String:
    """Re-encode Windows-1252/Latin-1 bytes as UTF-8."""
    var bytes = source.as_bytes()
    var out = String()
    var i = 0
    while i < len(bytes):
        if bytes[i] < 0x80:
            var run_start = i
            while i < len(bytes) and bytes[i] < 0x80:
                i += 1
            out += String(StringSlice(unsafe_from_utf8=bytes[run_start:i]))
        else:
            _append_codepoint(out, _cp1252_codepoint(bytes[i]))
            i += 1
    return out^


def _declared_encoding(source: String) -> String:
    """Lowercased encoding from the XML declaration, or "" if absent."""
    var bytes = source.as_bytes()
    if len(bytes) < 6:
        return String()
    # Only look inside an XML declaration at the very start.
    var limit = len(bytes)
    if limit > 200:
        limit = 200
    var head = String(StringSlice(unsafe_from_utf8=bytes[0:limit]))
    if not head.startswith("<?xml"):
        return String()
    var decl_end = head.find("?>")
    if decl_end == -1:
        return String()
    var enc_pos = head.find("encoding")
    if enc_pos == -1 or enc_pos > decl_end:
        return String()
    # Find the quoted value after "encoding".
    var i = enc_pos + 8
    while i < decl_end and (
        bytes[i] == _EQUALS or _is_space(bytes[i])
    ):
        i += 1
    if i >= decl_end or (bytes[i] != _SQUOTE and bytes[i] != _DQUOTE):
        return String()
    var quote = bytes[i]
    i += 1
    var start = i
    while i < decl_end and bytes[i] != quote:
        i += 1
    return String(StringSlice(unsafe_from_utf8=bytes[start:i])).lower()


def _transcode_utf16(data: Span[UInt8, _], little_endian: Bool) -> String:
    """Decode UTF-16 (after the BOM) to UTF-8, with U+FFFD recovery."""
    var out = String()
    var i = 2  # skip BOM
    while i + 1 < len(data):
        var unit: Int
        if little_endian:
            unit = Int(data[i]) | (Int(data[i + 1]) << 8)
        else:
            unit = (Int(data[i]) << 8) | Int(data[i + 1])
        i += 2
        if unit >= 0xD800 and unit <= 0xDBFF:
            # High surrogate: needs a following low surrogate.
            if i + 1 < len(data):
                var low: Int
                if little_endian:
                    low = Int(data[i]) | (Int(data[i + 1]) << 8)
                else:
                    low = (Int(data[i]) << 8) | Int(data[i + 1])
                if low >= 0xDC00 and low <= 0xDFFF:
                    i += 2
                    var cp = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                    _append_codepoint(out, cp)
                    continue
            _append_codepoint(out, 0xFFFD)
        elif unit >= 0xDC00 and unit <= 0xDFFF:
            _append_codepoint(out, 0xFFFD)  # unpaired low surrogate
        else:
            _append_codepoint(out, unit)
    if i < len(data):
        _append_codepoint(out, 0xFFFD)  # trailing odd byte
    return out^


def _utf8_lossy(data: Span[UInt8, _]) -> String:
    """Build a String from bytes, replacing invalid UTF-8 with U+FFFD."""
    var out = String()
    var i = 0
    var n = len(data)
    while i < n:
        var b = data[i]
        if b < 0x80:
            var run_start = i
            while i < n and data[i] < 0x80:
                i += 1
            out += String(StringSlice(unsafe_from_utf8=data[run_start:i]))
            continue
        var seq_len = 0
        var cp = 0
        if b >= 0xC2 and b <= 0xDF:
            seq_len = 2
            cp = Int(b) & 0x1F
        elif b >= 0xE0 and b <= 0xEF:
            seq_len = 3
            cp = Int(b) & 0x0F
        elif b >= 0xF0 and b <= 0xF4:
            seq_len = 4
            cp = Int(b) & 0x07
        if seq_len == 0 or i + seq_len > n:
            _append_codepoint(out, 0xFFFD)
            i += 1
            continue
        var ok = True
        for k in range(1, seq_len):
            var c = data[i + k]
            if c < 0x80 or c > 0xBF:
                ok = False
                break
            cp = (cp << 6) | (Int(c) & 0x3F)
        if not ok or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF):
            _append_codepoint(out, 0xFFFD)
            i += 1
            continue
        out += String(StringSlice(unsafe_from_utf8=data[i : i + seq_len]))
        i += seq_len
    return out^


def normalize_encoding_bytes(data: Span[UInt8, _]) raises -> String:
    """Produce a valid UTF-8 String from raw feed bytes.

    Handles UTF-16 (LE/BE, by BOM), UTF-8 BOM stripping, declared
    Latin-1/CP1252 transcoding, and lossy U+FFFD recovery for invalid
    UTF-8 sequences. Raises for encodings that can't be handled.
    """
    if len(data) >= 2:
        if data[0] == 0xFF and data[1] == 0xFE:
            return _transcode_utf16(data, little_endian=True)
        if data[0] == 0xFE and data[1] == 0xFF:
            return _transcode_utf16(data, little_endian=False)
    var body = data
    if len(data) >= 3 and data[0] == 0xEF and data[1] == 0xBB and (
        data[2] == 0xBF
    ):
        body = data[3:]
    # The declaration is ASCII, so a lossy view is safe for sniffing.
    var head_len = len(body)
    if head_len > 200:
        head_len = 200
    var head = _utf8_lossy(body[0:head_len])
    var enc = _declared_encoding(head)
    if (
        enc == "iso-8859-1"
        or enc == "latin-1"
        or enc == "latin1"
        or enc == "windows-1252"
        or enc == "cp1252"
    ):
        var latin = String(StringSlice(unsafe_from_utf8=body))
        return _transcode_latin(latin)
    if (
        enc.byte_length() == 0
        or enc == "utf-8"
        or enc == "utf8"
        or enc == "us-ascii"
        or enc == "ascii"
    ):
        return _utf8_lossy(body)
    raise Error("mojo-xml: unsupported encoding: " + enc)


def normalize_encoding(var source: String) raises -> String:
    """String-input variant of `normalize_encoding_bytes`."""
    return normalize_encoding_bytes(source.as_bytes())


def _normalize_newlines(var s: String) -> String:
    """XML 1.0 §2.11 line-ending normalization.

    Translate the two-byte sequence CR-LF and any lone CR to a single LF.
    Applied to the whole document before tokenizing, so it covers element
    content, CDATA sections, and attribute values uniformly (matching
    expat/CPython). Character references such as `&#13;` are literal ASCII
    text at this stage and survive to be decoded later, so an author who
    wants a real CR can still get one.
    """
    var bytes = s.as_bytes()
    var has_cr = False
    for b in bytes:
        if b == 0x0D:
            has_cr = True
            break
    if not has_cr:
        return s^
    var out = String()
    var i = 0
    var n = len(bytes)
    while i < n:
        if bytes[i] != 0x0D:
            var run_start = i
            while i < n and bytes[i] != 0x0D:
                i += 1
            out += String(StringSlice(unsafe_from_utf8=bytes[run_start:i]))
            continue
        out += "\n"
        i += 1
        if i < n and bytes[i] == 0x0A:
            i += 1  # collapse CR-LF into the single LF already emitted
    return out^


def _normalize_attr_ws(var raw: String) -> String:
    """XML attribute-value normalization for CDATA-type attributes.

    Every literal whitespace byte (tab or LF; CR has already been folded to
    LF document-wide by `_normalize_newlines`) is replaced by a single
    space, per the XML spec's attribute-value normalization rules. This runs
    on the raw slice *before* entity decoding, so character references like
    `&#9;`/`&#10;` — still literal `&#9;` text here — are preserved, again
    matching expat/CPython. All attributes are treated as CDATA type (there
    is no DTD to declare otherwise), so no further trimming/collapsing.
    """
    var bytes = raw.as_bytes()
    var has_ws = False
    for b in bytes:
        if b == 0x09 or b == 0x0A:
            has_ws = True
            break
    if not has_ws:
        return raw^
    var out = String()
    var i = 0
    var n = len(bytes)
    while i < n:
        var b = bytes[i]
        if b != 0x09 and b != 0x0A:
            var run_start = i
            while i < n and bytes[i] != 0x09 and bytes[i] != 0x0A:
                i += 1
            out += String(StringSlice(unsafe_from_utf8=bytes[run_start:i]))
            continue
        out += " "
        i += 1
    return out^


@fieldwise_init
struct XmlEvent(Copyable, Movable, Writable):
    """One parse event. `attrs` is populated only for EVENT_START."""

    var kind: Int
    var name: String
    var text: String
    var attrs: Dict[String, String]

    @staticmethod
    def start(var name: String, var attrs: Dict[String, String]) -> XmlEvent:
        return XmlEvent(EVENT_START, name^, String(), attrs^)

    @staticmethod
    def end(var name: String) -> XmlEvent:
        return XmlEvent(EVENT_END, name^, String(), Dict[String, String]())

    @staticmethod
    def text_event(var text: String) -> XmlEvent:
        return XmlEvent(EVENT_TEXT, String(), text^, Dict[String, String]())

    @staticmethod
    def eof() -> XmlEvent:
        return XmlEvent(EVENT_EOF, String(), String(), Dict[String, String]())

    def write_to(self, mut writer: Some[Writer]):
        if self.kind == EVENT_START:
            writer.write("Start(", self.name, ")")
        elif self.kind == EVENT_END:
            writer.write("End(", self.name, ")")
        elif self.kind == EVENT_TEXT:
            writer.write("Text(", self.text, ")")
        else:
            writer.write("Eof")


struct XmlPullParser(Copyable, Movable):
    """Pull events with `next_event()` until it returns EVENT_EOF.

    With `strict=True` the parser validates well-formedness as it goes —
    mismatched or stray end tags, elements left open at EOF, and
    malformed or unknown entities raise with a line/column location
    instead of being liberally recovered. Useful for debugging a feed
    you produce; leave it off for feeds you merely consume.
    """

    var src: String
    var pos: Int
    var strict: Bool
    var _pending_end: String
    var _has_pending_end: Bool
    var _open: List[String]

    def __init__(out self, var source: String, *, strict: Bool = False) raises:
        self.src = _normalize_newlines(normalize_encoding(source^))
        self.pos = 0
        self.strict = strict
        self._pending_end = String()
        self._has_pending_end = False
        self._open = List[String]()

    def _location(self, p: Int) -> String:
        """Human-readable "line L, column C" for byte offset `p`.

        Computed lazily (only on error paths), so the happy path pays
        nothing for location tracking.
        """
        var bytes = self.src.as_bytes()
        var line = 1
        var col = 1
        var limit = p
        if limit > len(bytes):
            limit = len(bytes)
        for i in range(limit):
            if bytes[i] == 0x0A:
                line += 1
                col = 1
            else:
                col += 1
        return String("line ") + String(line) + ", column " + String(col)

    def _strict_error(self, msg: String, p: Int) -> Error:
        return Error(
            "mojo-xml [strict]: " + msg + " (" + self._location(p) + ")"
        )

    def _len(self) -> Int:
        return self.src.byte_length()

    def _at(self, i: Int) -> UInt8:
        return self.src.as_bytes()[i]

    def _slice_to_string(self, start: Int, end: Int) -> String:
        return String(
            StringSlice(unsafe_from_utf8=self.src.as_bytes()[start:end])
        )

    def _starts_with(self, i: Int, literal: StaticString) -> Bool:
        var lit_bytes = literal.as_bytes()
        if i + len(lit_bytes) > self._len():
            return False
        for k in range(len(lit_bytes)):
            if self._at(i + k) != lit_bytes[k]:
                return False
        return True

    def _find(self, start: Int, literal: StaticString) raises -> Int:
        """Byte offset of `literal` at or after `start`, or raises."""
        var i = start
        while i < self._len():
            if self._starts_with(i, literal):
                return i
            i += 1
        raise Error(
            String("mojo-xml: unterminated construct, expected: ")
            + String(literal)
        )

    def _skip_space(mut self):
        while self.pos < self._len() and _is_space(self._at(self.pos)):
            self.pos += 1

    def _decode_entities(self, var raw: String) raises -> String:
        # Zero-copy fast path: most text and attribute values contain no
        # entities at all — hand the string back untouched.
        var has_amp = False
        for b in raw.as_bytes():
            if b == _AMP:
                has_amp = True
                break
        if not has_amp:
            return raw^
        var bytes = raw.as_bytes()
        var out = String()
        var i = 0
        while i < len(bytes):
            var b = bytes[i]
            if b != _AMP:
                # Fast path: copy the contiguous run without entities.
                var run_start = i
                while i < len(bytes) and bytes[i] != _AMP:
                    i += 1
                out += String(StringSlice(unsafe_from_utf8=bytes[run_start:i]))
                continue
            # Find the terminating ';' within a sane distance.
            var semi = -1
            var j = i + 1
            while j < len(bytes) and j < i + 12:
                if bytes[j] == _SEMI:
                    semi = j
                    break
                j += 1
            if semi == -1:
                if self.strict:
                    raise self._strict_error(
                        "bare '&' without a terminated entity", self.pos
                    )
                # Malformed bare '&' — pass it through (liberal parsing).
                out += String(StringSlice(unsafe_from_utf8=bytes[i : i + 1]))
                i += 1
                continue
            var entity = self._entity_body(raw, i + 1, semi)
            out += entity
            i = semi + 1
        return out^

    def _entity_body(self, raw: String, start: Int, end: Int) raises -> String:
        var bytes = raw.as_bytes()
        var out = String()
        if start < end and bytes[start] == _HASH:
            # Numeric character reference: &#38; or &#x26;
            var cp = 0
            var k = start + 1
            var is_hex = k < end and (
                bytes[k] == UInt8(ord("x")) or bytes[k] == UInt8(ord("X"))
            )
            if is_hex:
                k += 1
            # Malformed references pass through verbatim (liberal parsing)
            # rather than failing the whole document.
            var valid = k < end
            while k < end:
                var d = Int(bytes[k])
                if is_hex:
                    if d >= ord("0") and d <= ord("9"):
                        cp = cp * 16 + (d - ord("0"))
                    elif d >= ord("a") and d <= ord("f"):
                        cp = cp * 16 + (d - ord("a") + 10)
                    elif d >= ord("A") and d <= ord("F"):
                        cp = cp * 16 + (d - ord("A") + 10)
                    else:
                        valid = False
                        break
                else:
                    if d >= ord("0") and d <= ord("9"):
                        cp = cp * 10 + (d - ord("0"))
                    else:
                        valid = False
                        break
                k += 1
            if not valid:
                if self.strict:
                    raise self._strict_error(
                        "malformed numeric character reference", self.pos
                    )
                out += String("&")
                out += String(StringSlice(unsafe_from_utf8=bytes[start:end]))
                out += String(";")
                return out^
            _append_codepoint(out, cp)
            return out^
        var name = String(StringSlice(unsafe_from_utf8=bytes[start:end]))
        if name == "amp":
            return String("&")
        if name == "lt":
            return String("<")
        if name == "gt":
            return String(">")
        if name == "quot":
            return String('"')
        if name == "apos":
            return String("'")
        # Unknown named entity — preserve it verbatim (liberal parsing).
        if self.strict:
            raise self._strict_error(
                "unknown entity &" + name + ";", self.pos
            )
        return String("&") + name + String(";")

    def _read_name(mut self) -> String:
        var start = self.pos
        while self.pos < self._len():
            var b = self._at(self.pos)
            if _is_space(b) or b == _GT or b == _SLASH or b == _EQUALS:
                break
            self.pos += 1
        return self._slice_to_string(start, self.pos)

    def _read_attrs(mut self) raises -> Dict[String, String]:
        var attrs = Dict[String, String]()
        while True:
            self._skip_space()
            if self.pos >= self._len():
                raise Error("mojo-xml: unterminated start tag")
            var b = self._at(self.pos)
            if b == _GT or b == _SLASH:
                return attrs^
            var name = self._read_name()
            self._skip_space()
            if self.pos < self._len() and self._at(self.pos) == _EQUALS:
                self.pos += 1
                self._skip_space()
                if self.pos >= self._len():
                    raise Error("mojo-xml: unterminated attribute")
                var quote = self._at(self.pos)
                if quote != _SQUOTE and quote != _DQUOTE:
                    raise Error("mojo-xml: unquoted attribute value")
                self.pos += 1
                var vstart = self.pos
                while self.pos < self._len() and self._at(self.pos) != quote:
                    self.pos += 1
                if self.pos >= self._len():
                    raise Error("mojo-xml: unterminated attribute value")
                var raw = self._slice_to_string(vstart, self.pos)
                self.pos += 1  # closing quote
                attrs[name] = self._decode_entities(_normalize_attr_ws(raw^))
            else:
                # Attribute without a value (invalid XML, tolerated).
                attrs[name] = String()

    def next_event(mut self) raises -> XmlEvent:
        if self._has_pending_end:
            self._has_pending_end = False
            return XmlEvent.end(self._pending_end.copy())
        while True:
            if self.pos >= self._len():
                if self.strict and len(self._open) > 0:
                    raise self._strict_error(
                        "unclosed element <"
                        + self._open[len(self._open) - 1]
                        + "> at end of input",
                        self.pos,
                    )
                return XmlEvent.eof()
            if self._at(self.pos) != _LT:
                # Text run up to the next tag.
                var start = self.pos
                while self.pos < self._len() and self._at(self.pos) != _LT:
                    self.pos += 1
                var raw = self._slice_to_string(start, self.pos)
                return XmlEvent.text_event(self._decode_entities(raw))
            # self.pos is at '<'. Dispatch on the next byte first so the
            # overwhelmingly common plain tags skip the literal probes.
            var next_b: UInt8 = 0
            if self.pos + 1 < self._len():
                next_b = self._at(self.pos + 1)
            if next_b == _BANG:
                if self._starts_with(self.pos, "<!--"):
                    self.pos = self._find(self.pos + 4, "-->") + 3
                    continue
                if self._starts_with(self.pos, "<![CDATA["):
                    var start = self.pos + 9
                    var close = self._find(start, "]]>")
                    self.pos = close + 3
                    # CDATA content is literal — no entity decoding.
                    return XmlEvent.text_event(
                        self._slice_to_string(start, close)
                    )
                # DOCTYPE and friends; tolerate an internal subset [...].
                self.pos += 2
                var depth = 0
                while self.pos < self._len():
                    var b = self._at(self.pos)
                    if b == _LBRACKET:
                        depth += 1
                    elif b == _RBRACKET:
                        depth -= 1
                    elif b == _GT and depth <= 0:
                        self.pos += 1
                        break
                    self.pos += 1
                continue
            if next_b == _QUESTION:
                self.pos = self._find(self.pos + 2, "?>") + 2
                continue
            if next_b == _SLASH:
                var tag_start = self.pos
                self.pos += 2
                var name = self._read_name()
                self._skip_space()
                if self.pos >= self._len() or self._at(self.pos) != _GT:
                    raise Error("mojo-xml: malformed end tag: " + name)
                self.pos += 1
                if self.strict:
                    if len(self._open) == 0:
                        raise self._strict_error(
                            "stray end tag </" + name + ">", tag_start
                        )
                    var expected = self._open[len(self._open) - 1].copy()
                    if expected != name:
                        raise self._strict_error(
                            "mismatched end tag </" + name
                            + ">, expected </" + expected + ">",
                            tag_start,
                        )
                    _ = self._open.pop()
                return XmlEvent.end(name^)
            # Start tag.
            self.pos += 1
            var name = self._read_name()
            if name.byte_length() == 0:
                raise Error("mojo-xml: empty element name")
            var attrs = self._read_attrs()
            var self_closing = False
            if self._at(self.pos) == _SLASH:
                self_closing = True
                self.pos += 1
                self._skip_space()
            if self.pos >= self._len() or self._at(self.pos) != _GT:
                raise Error("mojo-xml: malformed start tag: " + name)
            self.pos += 1
            if self_closing:
                self._pending_end = name.copy()
                self._has_pending_end = True
            elif self.strict:
                self._open.append(name.copy())
            return XmlEvent.start(name^, attrs^)
