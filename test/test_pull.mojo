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
    var events = _events('<e url="http://x.mp3" length="42" type="audio/mpeg"/>')
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
    var events = _events("<t>a &amp; b &lt;c&gt; &quot;d&quot; &apos;e&apos;</t>")
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
        0xFF, 0xFE,
        0x3C, 0x00, 0x61, 0x00, 0x3E, 0x00,  # <a>
        0xE9, 0x00,                            # é
        0x3C, 0x00, 0x2F, 0x00, 0x61, 0x00, 0x3E, 0x00,  # </a>
    ]
    var parser_input = String(StringSlice(unsafe_from_utf8=Span(raw_bytes)))
    var events = _events(parser_input^)
    assert_equal(events[0].name, "a")
    assert_equal(events[1].text, "é")


def test_utf16_be_transcoded() raises:
    # UTF-16BE with BOM: <a>x</a>
    var raw_bytes: List[UInt8] = [
        0xFE, 0xFF,
        0x00, 0x3C, 0x00, 0x61, 0x00, 0x3E,
        0x00, 0x78,
        0x00, 0x3C, 0x00, 0x2F, 0x00, 0x61, 0x00, 0x3E,
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
