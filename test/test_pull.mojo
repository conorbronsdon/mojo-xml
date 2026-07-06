from std.testing import assert_equal, assert_true, assert_raises, TestSuite

from xml.pull import (
    XmlPullParser,
    XmlEvent,
    EVENT_START,
    EVENT_END,
    EVENT_TEXT,
    EVENT_EOF,
)


def _events(var source: String) raises -> List[XmlEvent]:
    var parser = XmlPullParser(source^)
    var out = List[XmlEvent]()
    while True:
        var event = parser.next_event()
        if event.kind == EVENT_EOF:
            break
        out.append(event^)
    return out^


def test_simple_element() raises:
    var events = _events("<a>hello</a>")
    assert_equal(len(events), 3)
    assert_equal(events[0].kind, EVENT_START)
    assert_equal(events[0].name, "a")
    assert_equal(events[1].kind, EVENT_TEXT)
    assert_equal(events[1].text, "hello")
    assert_equal(events[2].kind, EVENT_END)
    assert_equal(events[2].name, "a")


def test_attributes() raises:
    var events = _events(
        '<e url="http://x.mp3" length="42" type="audio/mpeg"/>'
    )
    assert_equal(events[0].kind, EVENT_START)
    assert_equal(events[0].attrs["url"], "http://x.mp3")
    assert_equal(events[0].attrs["length"], "42")
    assert_equal(events[0].attrs["type"], "audio/mpeg")
    # Self-closing element emits a synthetic end event.
    assert_equal(events[1].kind, EVENT_END)
    assert_equal(events[1].name, "e")


def test_single_quoted_attribute() raises:
    var events = _events("<e a='b c'/>")
    assert_equal(events[0].attrs["a"], "b c")


def test_entities_in_text() raises:
    var events = _events(
        "<t>a &amp; b &lt;c&gt; &quot;d&quot; &apos;e&apos;</t>"
    )
    assert_equal(events[1].text, "a & b <c> \"d\" 'e'")


def test_numeric_entities() raises:
    # decimal, hex, and a multi-byte codepoint (right single quote U+2019)
    var events = _events("<t>&#38;&#x26;&#8217;</t>")
    assert_equal(events[1].text, "&&’")


def test_unknown_entity_preserved() raises:
    var events = _events("<t>&nbsp;</t>")
    assert_equal(events[1].text, "&nbsp;")


def test_malformed_numeric_entities_preserved() raises:
    # No digits / bad digits pass through verbatim, not NUL bytes or errors.
    var events = _events("<t>&#; &#x; &#12a;</t>")
    assert_equal(events[1].text, "&#; &#x; &#12a;")


def test_out_of_range_codepoint_becomes_replacement() raises:
    # Beyond U+10FFFF and surrogates must not emit invalid UTF-8.
    var events = _events("<t>&#x110000;&#xD800;</t>")
    assert_equal(events[1].text, "��")


def test_entities_in_attributes() raises:
    var events = _events('<e title="a &amp; b"/>')
    assert_equal(events[0].attrs["title"], "a & b")


def test_cdata_is_literal() raises:
    var events = _events("<t><![CDATA[<b>bold &amp; raw</b>]]></t>")
    assert_equal(events[1].kind, EVENT_TEXT)
    assert_equal(events[1].text, "<b>bold &amp; raw</b>")


def test_comments_and_pi_skipped() raises:
    var source: String = (
        '<?xml version="1.0"?><!-- comment --><a><!-- inner -->x</a>'
    )
    var events = _events(source^)
    assert_equal(len(events), 3)
    assert_equal(events[0].name, "a")
    assert_equal(events[1].text, "x")


def test_doctype_skipped() raises:
    var events = _events("<!DOCTYPE html><a>x</a>")
    assert_equal(events[0].kind, EVENT_START)
    assert_equal(events[0].name, "a")


def test_nested_elements() raises:
    var events = _events("<a><b>x</b><c/></a>")
    assert_equal(events[0].name, "a")
    assert_equal(events[1].name, "b")
    assert_equal(events[2].text, "x")
    assert_equal(events[3].kind, EVENT_END)
    assert_equal(events[3].name, "b")
    assert_equal(events[4].name, "c")
    assert_equal(events[5].kind, EVENT_END)
    assert_equal(events[5].name, "c")
    assert_equal(events[6].kind, EVENT_END)
    assert_equal(events[6].name, "a")


def test_namespaced_names_kept_literal() raises:
    var events = _events("<itunes:duration>3600</itunes:duration>")
    assert_equal(events[0].name, "itunes:duration")


def test_utf8_bom_stripped() raises:
    var bom_bytes: List[UInt8] = [0xEF, 0xBB, 0xBF]
    var bom = String(StringSlice(unsafe_from_utf8=Span(bom_bytes)))
    var events = _events(bom + "<a>x</a>")
    assert_equal(events[0].kind, EVENT_START)
    assert_equal(events[0].name, "a")


def test_latin1_transcoded() raises:
    # 0xE9 = é in Latin-1; 0x92 = right single quote in CP1252.
    var declared: String = "<?xml version='1.0' encoding='ISO-8859-1'?><t>"
    var raw = List[UInt8]()
    for b in declared.as_bytes():
        raw.append(b)
    raw.append(0xE9)
    raw.append(0x92)
    for b in "</t>".as_bytes():
        raw.append(b)
    var source = String(StringSlice(unsafe_from_utf8=Span(raw)))
    var events = _events(source^)
    assert_equal(events[1].text, "é’")


def test_utf16_le_transcoded() raises:
    # UTF-16LE with BOM: <a>é</a> (é = U+00E9)
    var raw_bytes: List[UInt8] = [
        0xFF,
        0xFE,
        0x3C,
        0x00,
        0x61,
        0x00,
        0x3E,
        0x00,  # <a>
        0xE9,
        0x00,  # é
        0x3C,
        0x00,
        0x2F,
        0x00,
        0x61,
        0x00,
        0x3E,
        0x00,  # </a>
    ]
    var parser_input = String(StringSlice(unsafe_from_utf8=Span(raw_bytes)))
    var events = _events(parser_input^)
    assert_equal(events[0].name, "a")
    assert_equal(events[1].text, "é")


def test_utf16_be_transcoded() raises:
    # UTF-16BE with BOM: <a>x</a>
    var raw_bytes: List[UInt8] = [
        0xFE,
        0xFF,
        0x00,
        0x3C,
        0x00,
        0x61,
        0x00,
        0x3E,
        0x00,
        0x78,
        0x00,
        0x3C,
        0x00,
        0x2F,
        0x00,
        0x61,
        0x00,
        0x3E,
    ]
    var parser_input = String(StringSlice(unsafe_from_utf8=Span(raw_bytes)))
    var events = _events(parser_input^)
    assert_equal(events[1].text, "x")


def test_invalid_utf8_replaced_lossily() raises:
    # A stray 0xFF byte inside otherwise-valid UTF-8 text.
    var raw_bytes: List[UInt8] = []
    for b in "<t>a".as_bytes():
        raw_bytes.append(b)
    raw_bytes.append(0xFF)
    for b in "b</t>".as_bytes():
        raw_bytes.append(b)
    var parser_input = String(StringSlice(unsafe_from_utf8=Span(raw_bytes)))
    var events = _events(parser_input^)
    assert_equal(events[1].text, "a�b")


def test_unsupported_encoding_raises() raises:
    with assert_raises(contains="unsupported encoding"):
        _ = XmlPullParser("<?xml version='1.0' encoding='EBCDIC'?><a/>")


def _strict_events(var source: String) raises:
    var parser = XmlPullParser(source^, strict=True)
    while True:
        var event = parser.next_event()
        if event.kind == EVENT_EOF:
            break


def test_strict_accepts_valid_document() raises:
    _strict_events(
        '<?xml version="1.0"?><a x="1"><b>text &amp; more</b><c/></a>'
    )


def test_strict_mismatched_end_tag() raises:
    with assert_raises(contains="mismatched end tag"):
        _strict_events("<a><b>x</a></b>")


def test_strict_stray_end_tag() raises:
    with assert_raises(contains="stray end tag"):
        _strict_events("<a>x</a></b>")


def test_strict_unclosed_at_eof() raises:
    with assert_raises(contains="unclosed element"):
        _strict_events("<a><b>x</b>")


def test_strict_unknown_entity() raises:
    with assert_raises(contains="unknown entity"):
        _strict_events("<a>&nbsp;</a>")


def test_strict_bare_ampersand() raises:
    with assert_raises(contains="bare '&'"):
        _strict_events("<a>fish & chips</a>")


def test_strict_error_reports_location() raises:
    with assert_raises(contains="line 3"):
        _strict_events("<a>\n<b>\nx</a>\n</b>")


def test_strict_self_closing_ok() raises:
    _strict_events('<a><link href="x"/><enclosure url="y"/></a>')


def test_unterminated_tag_raises() raises:
    var parser = XmlPullParser("<a href=")
    with assert_raises():
        _ = parser.next_event()


def test_unterminated_cdata_raises() raises:
    var parser = XmlPullParser("<t><![CDATA[oops")
    _ = parser.next_event()  # <t>
    with assert_raises():
        _ = parser.next_event()


# --------------------------------------------------------------------------
# Line-ending normalization (XML 1.0 §2.11) — CRLF and lone CR fold to LF,
# but character references stay literal. Matches expat/CPython.
# --------------------------------------------------------------------------


def test_crlf_normalized_in_text() raises:
    var events = _events("<a>x\r\ny</a>")
    assert_equal(events[1].text, "x\ny")


def test_lone_cr_normalized_in_text() raises:
    var events = _events("<a>x\ry</a>")
    assert_equal(events[1].text, "x\ny")


def test_charref_cr_preserved() raises:
    # &#13; is a real CR request and must survive normalization.
    var events = _events("<a>x&#13;y</a>")
    assert_equal(events[1].text, "x\ry")


def test_cdata_line_endings_normalized() raises:
    var events = _events("<a><![CDATA[x\r\ny\rz]]></a>")
    assert_equal(events[1].text, "x\ny\nz")


# --------------------------------------------------------------------------
# Attribute-value whitespace normalization — literal tab/newline become a
# single space each (no collapsing for CDATA-type attrs), char refs preserved.
# --------------------------------------------------------------------------


def test_attr_literal_tab_normalized() raises:
    var events = _events('<a b="x\ty"/>')
    assert_equal(events[0].attrs["b"], "x y")


def test_attr_literal_newline_normalized() raises:
    var events = _events('<a b="x\ny"/>')
    assert_equal(events[0].attrs["b"], "x y")


def test_attr_crlf_normalized_to_single_space() raises:
    # CRLF folds to one LF (line normalization) then to one space (attr norm).
    var events = _events('<a b="x\r\ny"/>')
    assert_equal(events[0].attrs["b"], "x y")


def test_attr_multiple_ws_not_collapsed() raises:
    # Each whitespace char becomes its own space; CDATA-type attrs aren't
    # collapsed or trimmed.
    var events = _events('<a b="x\n\ty"/>')
    assert_equal(events[0].attrs["b"], "x  y")


def test_attr_charref_whitespace_preserved() raises:
    var events = _events('<a b="x&#9;y&#10;z"/>')
    assert_equal(events[0].attrs["b"], "x\ty\nz")


# --------------------------------------------------------------------------
# Character-reference validation against the XML 1.0 Char production
# (§2.2). Invalid references — NUL, other C0 controls, surrogates, the
# U+FFFE/U+FFFF noncharacters, out-of-range — are rejected in strict mode
# and substituted with U+FFFD in liberal mode (never injected verbatim).
# --------------------------------------------------------------------------


def test_liberal_nul_char_ref_becomes_replacement() raises:
    # The headline: &#0; must never inject a NUL byte into decoded output.
    var events = _events("<t>&#0;</t>")
    assert_equal(events[1].text, "�")
    # And specifically: no NUL byte survived.
    for b in events[1].text.as_bytes():
        assert_true(b != 0)


def test_liberal_c0_control_char_ref_becomes_replacement() raises:
    var events = _events("<t>&#8;</t>")
    assert_equal(events[1].text, "�")


def test_strict_nul_char_ref_raises() raises:
    with assert_raises(contains="invalid character number"):
        _strict_events("<t>&#0;</t>")


def test_strict_c0_control_char_ref_raises() raises:
    with assert_raises(contains="invalid character number"):
        _strict_events("<t>&#8;</t>")


def test_strict_noncharacter_ref_raises() raises:
    with assert_raises(contains="invalid character number"):
        _strict_events("<t>&#xFFFE;</t>")


def test_strict_surrogate_char_ref_raises() raises:
    with assert_raises(contains="invalid character number"):
        _strict_events("<t>&#xD800;</t>")


def test_strict_out_of_range_char_ref_raises() raises:
    with assert_raises(contains="invalid character number"):
        _strict_events("<t>&#x110000;</t>")


def test_strict_legal_whitespace_char_refs_ok() raises:
    # #x9, #xA, #xD are the three C0 controls the Char production allows.
    var parser = XmlPullParser("<t>&#x9;&#xA;&#xD;A</t>", strict=True)
    _ = parser.next_event()  # <t>
    var text = parser.next_event()
    assert_equal(text.text, "\t\n\rA")


# --------------------------------------------------------------------------
# Strict-mode well-formedness of names, attributes, comments, and content.
# --------------------------------------------------------------------------


def test_strict_invalid_element_name_raises() raises:
    with assert_raises(contains="name"):
        _strict_events("<a<b>x</a<b>")


def test_strict_valueless_attribute_raises() raises:
    with assert_raises(contains="no value"):
        _strict_events("<a b>x</a>")


def test_strict_duplicate_attribute_raises() raises:
    with assert_raises(contains="duplicate attribute"):
        _strict_events("<a b='1' b='2'>x</a>")


def test_strict_raw_lt_in_attr_value_raises() raises:
    with assert_raises(contains="'<' not allowed"):
        _strict_events("<a b='x<y'>x</a>")


def test_strict_cdata_close_in_content_raises() raises:
    with assert_raises(contains="']]>' not allowed"):
        _strict_events("<a>foo]]>bar</a>")


def test_strict_double_dash_in_comment_raises() raises:
    with assert_raises(contains="'--' not allowed"):
        _strict_events("<a><!-- a--b --></a>")


def test_liberal_still_tolerates_valueless_and_duplicate_attrs() raises:
    # Liberal mode stays deliberately forgiving for feeds you merely consume.
    var events = _events("<a b c='1' c='2'>x</a>")
    assert_equal(events[0].attrs["b"], "")
    assert_equal(events[0].attrs["c"], "2")  # last-wins, no raise


# --------------------------------------------------------------------------
# DOCTYPE scanning is quote- and comment-aware; internal <!ENTITY> decls
# are captured and resolved.
# --------------------------------------------------------------------------


def test_doctype_quoted_gt_does_not_end_early() raises:
    # The '>' inside the SYSTEM literal must not terminate the DOCTYPE.
    var events = _events('<!DOCTYPE r SYSTEM "a>b"><r>x</r>')
    assert_equal(events[0].kind, EVENT_START)
    assert_equal(events[0].name, "r")
    assert_equal(events[1].text, "x")


def test_doctype_subset_bracket_in_literal_does_not_end_early() raises:
    var events = _events('<!DOCTYPE r [ <!ENTITY x "a]b"> ]><r>y</r>')
    assert_equal(events[0].name, "r")
    assert_equal(events[1].text, "y")


def test_doctype_comment_in_internal_subset_skipped() raises:
    var events = _events("<!DOCTYPE r [ <!-- > ] --> ]><r>z</r>")
    assert_equal(events[0].name, "r")
    assert_equal(events[1].text, "z")


def test_internal_entity_declaration_resolved() raises:
    var events = _events('<!DOCTYPE r [ <!ENTITY foo "bar"> ]><r>&foo;</r>')
    assert_equal(events[0].name, "r")
    assert_equal(events[1].text, "bar")


def test_internal_entity_with_charref_value() raises:
    var events = _events(
        '<!DOCTYPE r [ <!ENTITY foo "a &amp; b"> ]><r>&foo;</r>'
    )
    assert_equal(events[1].text, "a & b")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
