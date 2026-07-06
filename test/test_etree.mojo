from std.testing import (
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
    TestSuite,
)

from xml.etree import Element, fromstring, tostring, SubElement


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------


def _tree_equal(a: Element, b: Element) -> Bool:
    """Structural equality: tag, text, tail, attributes, children."""
    if a.tag != b.tag or a.text != b.text or a.tail != b.tail:
        return False
    if len(a.attrib) != len(b.attrib):
        return False
    if len(a.children) != len(b.children):
        return False
    for entry in a.attrib.items():
        if b.get(entry.key, "\x01__missing__") != entry.value:
            return False
    for i in range(len(a.children)):
        if not _tree_equal(a.children[i], b.children[i]):
            return False
    return True


# --------------------------------------------------------------------------
# Basic parsing
# --------------------------------------------------------------------------


def test_simple_parse() raises:
    var root = fromstring("<a>hello</a>")
    assert_equal(root.tag, "a")
    assert_equal(root.text, "hello")
    assert_equal(len(root), 0)


def test_attributes() raises:
    var root = fromstring('<e url="http://x" length="42"/>')
    assert_equal(root.get("url"), "http://x")
    assert_equal(root.get("length"), "42")
    assert_equal(root.get("missing"), "")
    assert_equal(root.get("missing", "fallback"), "fallback")


def test_single_quoted_attr() raises:
    var root = fromstring("<e a='b c'/>")
    assert_equal(root.get("a"), "b c")


def test_nested_children() raises:
    var root = fromstring("<a><b/><c/><d/></a>")
    assert_equal(len(root), 3)
    assert_equal(root.children[0].tag, "b")
    assert_equal(root.children[1].tag, "c")
    assert_equal(root.children[2].tag, "d")


def test_self_closing_has_empty_text() raises:
    var root = fromstring("<a><b/></a>")
    assert_equal(len(root), 1)
    assert_equal(root.children[0].text, "")
    assert_equal(len(root.children[0]), 0)


# --------------------------------------------------------------------------
# Text / tail model (the part everyone gets wrong)
# --------------------------------------------------------------------------


def test_text_vs_tail() raises:
    var root = fromstring("<a>t0<b>hi</b>t1<c/>t2</a>")
    assert_equal(root.text, "t0")  # before first child
    assert_equal(root.children[0].tag, "b")
    assert_equal(root.children[0].text, "hi")
    assert_equal(root.children[0].tail, "t1")  # after </b>
    assert_equal(root.children[1].tag, "c")
    assert_equal(root.children[1].text, "")
    assert_equal(root.children[1].tail, "t2")  # after <c/>
    assert_equal(root.tail, "")  # root has no tail


def test_text_before_first_child_only() raises:
    # Text after a child (with no following sibling text) is that child's
    # tail, not the parent's text.
    var root = fromstring("<a><b/>after</a>")
    assert_equal(root.text, "")
    assert_equal(root.children[0].tail, "after")


def test_deep_tail() raises:
    var root = fromstring("<a><b><c/>x</b>y</a>")
    var b = root.children[0].copy()
    assert_equal(b.tag, "b")
    assert_equal(b.children[0].tail, "x")  # after <c/>, inside b
    assert_equal(b.tail, "y")  # after </b>, inside a


def test_whitespace_preserved() raises:
    var root = fromstring("<a>\n  <b/>\n</a>")
    assert_equal(root.text, "\n  ")
    assert_equal(root.children[0].tail, "\n")


# --------------------------------------------------------------------------
# Entities decode through to Element.text
# --------------------------------------------------------------------------


def test_entity_decoding() raises:
    var root = fromstring("<t>a &amp; b &lt;c&gt; &quot;d&quot;</t>")
    assert_equal(root.text, 'a & b <c> "d"')


def test_numeric_entity() raises:
    var root = fromstring("<t>&#38;&#x26;&#8217;</t>")
    assert_equal(root.text, "&&’")


def test_entity_in_attribute() raises:
    var root = fromstring('<e title="a &amp; b"/>')
    assert_equal(root.get("title"), "a & b")


def test_cdata_literal() raises:
    var root = fromstring("<t><![CDATA[<b>raw &amp; stuff</b>]]></t>")
    assert_equal(root.text, "<b>raw &amp; stuff</b>")


# --------------------------------------------------------------------------
# Namespaces -> Clark notation
# --------------------------------------------------------------------------


def test_prefixed_element() raises:
    var root = fromstring("<a:foo xmlns:a='http://x'><a:bar>v</a:bar></a:foo>")
    assert_equal(root.tag, "{http://x}foo")
    assert_equal(root.children[0].tag, "{http://x}bar")
    assert_equal(root.children[0].text, "v")


def test_default_namespace_on_elements() raises:
    var root = fromstring("<foo xmlns='http://d'><bar/></foo>")
    assert_equal(root.tag, "{http://d}foo")
    assert_equal(root.children[0].tag, "{http://d}bar")


def test_default_namespace_not_on_attrs() raises:
    # Default ns applies to element names but not unprefixed attributes.
    var root = fromstring("<foo xmlns='http://d' a='1'/>")
    assert_equal(root.tag, "{http://d}foo")
    assert_equal(root.get("a"), "1")  # attrib key stays "a"
    assert_equal(root.get("{http://d}a"), "")  # NOT namespaced


def test_prefixed_attribute() raises:
    var root = fromstring("<e xmlns:x='http://x' x:k='v' plain='p'/>")
    assert_equal(root.get("{http://x}k"), "v")
    assert_equal(root.get("plain"), "p")


def test_xmlns_not_kept_in_attrib() raises:
    var root = fromstring("<a xmlns='http://d' xmlns:x='http://x'/>")
    assert_equal(root.get("xmlns"), "")
    assert_equal(root.get("xmlns:x"), "")


def test_nested_namespace_scoping() raises:
    # Inner element rebinds prefix p; each resolves to its own scope.
    var doc: String = (
        "<p:a xmlns:p='http://one'><p:b xmlns:p='http://two'/></p:a>"
    )
    var root = fromstring(doc^)
    assert_equal(root.tag, "{http://one}a")
    assert_equal(root.children[0].tag, "{http://two}b")


# --------------------------------------------------------------------------
# find / findall / findtext / iter with paths
# --------------------------------------------------------------------------


def test_find_child() raises:
    var root = fromstring("<a><b>1</b><c>2</c></a>")
    var c = root.find("c")
    assert_equal(c.tag, "c")
    assert_equal(c.text, "2")


def test_find_path() raises:
    var root = fromstring("<a><b><c>deep</c></b></a>")
    var c = root.find("b/c")
    assert_equal(c.text, "deep")


def test_findall_multiple() raises:
    var root = fromstring("<a><b>1</b><b>2</b><c/><b>3</b></a>")
    var bs = root.findall("b")
    assert_equal(len(bs), 3)
    assert_equal(bs[0].text, "1")
    assert_equal(bs[1].text, "2")
    assert_equal(bs[2].text, "3")


def test_wildcard() raises:
    var root = fromstring("<a><b/><c/><d/></a>")
    var all = root.findall("*")
    assert_equal(len(all), 3)


def test_wildcard_path() raises:
    var root = fromstring("<a><b><x>1</x></b><c><x>2</x></c></a>")
    var xs = root.findall("*/x")
    assert_equal(len(xs), 2)
    assert_equal(xs[0].text, "1")
    assert_equal(xs[1].text, "2")


def test_descendant() raises:
    var root = fromstring(
        "<a><b><t>1</t></b><t>2</t><c><d><t>3</t></d></c></a>"
    )
    var ts = root.findall(".//t")
    assert_equal(len(ts), 3)


def test_descendant_path() raises:
    var root = fromstring("<a><b><t>1</t></b><b><t>2</t></b></a>")
    var ts = root.findall(".//b/t")
    assert_equal(len(ts), 2)
    assert_equal(ts[0].text, "1")
    assert_equal(ts[1].text, "2")


def test_find_clark_path() raises:
    # A slash inside the namespace URI must not be treated as a path sep.
    var root = fromstring("<a xmlns:x='http://ex.com/ns'><x:b>hi</x:b></a>")
    var b = root.find("{http://ex.com/ns}b")
    assert_equal(b.text, "hi")


def test_find_raises_when_missing() raises:
    var root = fromstring("<a><b/></a>")
    with assert_raises(contains="no element matches"):
        _ = root.find("z")


def test_find_opt() raises:
    var root = fromstring("<a><b>hit</b></a>")
    var found = root.find_opt("b")
    assert_true(Bool(found))
    assert_equal(found.value().text, "hit")
    var missing = root.find_opt("z")
    assert_false(Bool(missing))


def test_findtext() raises:
    var root = fromstring("<a><b>val</b></a>")
    assert_equal(root.findtext("b"), "val")
    assert_equal(root.findtext("z"), "")
    assert_equal(root.findtext("z", "dflt"), "dflt")


def test_iter_all() raises:
    var root = fromstring("<a><b><c/></b><d/></a>")
    var all = root.iter()
    # a, b, c, d  (self included, depth-first)
    assert_equal(len(all), 4)
    assert_equal(all[0].tag, "a")
    assert_equal(all[1].tag, "b")
    assert_equal(all[2].tag, "c")
    assert_equal(all[3].tag, "d")


def test_iter_by_tag() raises:
    var root = fromstring("<a><b/><c><b/></c><b/></a>")
    var bs = root.iter("b")
    assert_equal(len(bs), 3)


# --------------------------------------------------------------------------
# Mutation API
# --------------------------------------------------------------------------


def test_set_and_get() raises:
    var e = Element(String("x"))
    e.set("k", "v")
    assert_equal(e.get("k"), "v")
    e.set("k", "v2")
    assert_equal(e.get("k"), "v2")


def test_append_child() raises:
    var e = Element(String("root"))
    e.append(Element(String("kid")))
    assert_equal(len(e), 1)
    assert_equal(e.children[0].tag, "kid")


def test_subelement() raises:
    var e = Element(String("root"))
    var kid = SubElement(e, String("kid"))
    assert_equal(kid.tag, "kid")  # returned snapshot
    assert_equal(len(e), 1)  # and appended to parent
    assert_equal(e.children[0].tag, "kid")


# --------------------------------------------------------------------------
# Serialization
# --------------------------------------------------------------------------


def test_tostring_basic() raises:
    var root = fromstring("<a x='1'>hi</a>")
    assert_equal(tostring(root), '<a x="1">hi</a>')


def test_tostring_self_closing() raises:
    var root = fromstring("<a><b/></a>")
    assert_equal(tostring(root), "<a><b /></a>")


def test_tostring_escaping_text() raises:
    var e = Element(String("t"))
    e.text = String("a < b & c > d")
    assert_equal(tostring(e), "<t>a &lt; b &amp; c &gt; d</t>")


def test_tostring_escaping_attr() raises:
    var e = Element(String("t"))
    e.set("v", String('a"b&c<d'))
    assert_equal(tostring(e), '<t v="a&quot;b&amp;c&lt;d" />')


def test_roundtrip_structural() raises:
    var src: String = "<a x='1'>t0<b y='2'>hi</b>t1<c/>t2</a>"
    var tree = fromstring(src^)
    var reparsed = fromstring(tostring(tree))
    assert_true(_tree_equal(tree, reparsed))


def test_roundtrip_namespaced() raises:
    var src: String = "<a:foo xmlns:a='http://x'><a:bar k='v'>t</a:bar></a:foo>"
    var tree = fromstring(src^)
    var reparsed = fromstring(tostring(tree))
    assert_true(_tree_equal(tree, reparsed))
    # Both namespaced tags survive the round trip.
    assert_equal(reparsed.tag, "{http://x}foo")
    assert_equal(reparsed.children[0].tag, "{http://x}bar")


def test_roundtrip_idempotent() raises:
    var src: String = "<doc><item id='1'>a &amp; b</item><item id='2'/></doc>"
    var once = tostring(fromstring(src^))
    var twice = tostring(fromstring(once.copy()))
    assert_equal(once, twice)


# --------------------------------------------------------------------------
# Malformed input
# --------------------------------------------------------------------------


def test_mismatched_tag_raises() raises:
    with assert_raises(contains="mismatched end tag"):
        _ = fromstring("<a><b></a></b>")


def test_stray_end_tag_raises() raises:
    with assert_raises(contains="stray end tag"):
        _ = fromstring("<a>x</a></b>")


def test_unclosed_raises() raises:
    with assert_raises(contains="unclosed element"):
        _ = fromstring("<a><b>x</b>")


def test_undefined_entity_raises() raises:
    with assert_raises(contains="unknown entity"):
        _ = fromstring("<a>&nbsp;</a>")


def test_no_root_raises() raises:
    with assert_raises(contains="no root element"):
        _ = fromstring("   ")


# --- Regression: single-document-element well-formedness (review finding #1) --
# These slipped through 1500 fuzz iterations because every seed was single-root;
# without them a second root silently overwrote the first (data loss).


def test_two_roots_raises() raises:
    with assert_raises(contains="junk after document element"):
        _ = fromstring("<a/><b/>")


def test_sibling_roots_raises() raises:
    with assert_raises(contains="junk after document element"):
        _ = fromstring("<a></a><b></b>")


def test_junk_before_root_raises() raises:
    with assert_raises(contains="text outside the document element"):
        _ = fromstring("junk<a/>")


def test_trailing_text_raises() raises:
    with assert_raises(contains="text outside the document element"):
        _ = fromstring("<a/>tail")


def test_whitespace_around_root_ok() raises:
    # whitespace before/after the root is allowed and ignored
    var r = fromstring("  \n<a/>\n  ")
    assert_equal(r.tag, "a")


# --- Regression: unbound namespace prefixes (review finding #2) ---------------


def test_unbound_prefix_element_raises() raises:
    with assert_raises(contains="unbound namespace prefix"):
        _ = fromstring("<r><b:x/></r>")


def test_unbound_prefix_attr_raises() raises:
    with assert_raises(contains="unbound namespace prefix"):
        _ = fromstring("<r xmlns:a='u'><a:x b:y='1'/></r>")


def test_reserved_xml_prefix_ok() raises:
    # The `xml` prefix is implicitly bound to the reserved URI; xml:lang needs
    # no declaration and resolves to Clark notation, matching ElementTree.
    var r = fromstring("<r xml:lang='en'>hi</r>")
    assert_equal(r.get("{http://www.w3.org/XML/1998/namespace}lang"), "en")
    # The old literal key is NOT present.
    assert_equal(r.get("xml:lang"), "")


# --- Regression: attribute whitespace escaping matches CPython (finding #4) ---


def test_attr_whitespace_escaped() raises:
    var e = fromstring("<r a='x&#10;y&#9;z&#13;w'/>")
    # CPython _escape_attrib emits &#10; &#09; &#13; for LF/TAB/CR in attrs
    assert_equal(tostring(e), '<r a="x&#10;y&#09;z&#13;w" />')


# --- Character-data model corners: CDATA/comments merge into one text node ---
# CPython/expat coalesce adjacent character data (plain text, entities, and
# CDATA) and drop comments/PIs, leaving a single merged text/tail node.


def test_cdata_merges_with_surrounding_text() raises:
    var root = fromstring("<a>x &amp; y<![CDATA[ then &amp; stays]]> and z</a>")
    assert_equal(root.text, "x & y then &amp; stays and z")


def test_comment_merges_adjacent_text() raises:
    var root = fromstring("<a>foo<!-- c -->bar</a>")
    assert_equal(root.text, "foobar")


def test_comment_only_child_has_empty_text() raises:
    var root = fromstring("<a><!-- just a comment --></a>")
    assert_equal(root.text, "")
    assert_equal(len(root), 0)


def test_cdata_then_element_is_text_not_tail() raises:
    var root = fromstring("<a><![CDATA[t]]><b/></a>")
    assert_equal(root.text, "t")
    assert_equal(root.children[0].tail, "")


def test_sibling_same_prefix_different_uri() raises:
    # Each element's own xmlns binding wins; siblings resolve independently.
    var root = fromstring("<r><a:x xmlns:a='u1'/><a:y xmlns:a='u2'/></r>")
    assert_equal(root.children[0].tag, "{u1}x")
    assert_equal(root.children[1].tag, "{u2}y")


# --- Regression: line-ending + attribute normalization reach the DOM --------
# The corpus anchor caught these diverging from CPython; fixed in the pull
# parser and verified here at the tree level too.


def test_crlf_normalized_in_text_and_tail() raises:
    var root = fromstring("<a>x\r\ny<b/>t\r\nu</a>")
    assert_equal(root.text, "x\ny")
    assert_equal(root.children[0].tail, "t\nu")


def test_attr_whitespace_normalized_in_dom() raises:
    var root = fromstring('<a b="x\ty\n\tz"/>')
    assert_equal(root.get("b"), "x y  z")


# --- Regression: reserved xml prefix resolves to Clark notation --------------


def test_xml_prefix_on_element() raises:
    # An element (not just an attribute) using the xml prefix resolves too.
    var root = fromstring("<xml:doc xml:lang='en'>hi</xml:doc>")
    assert_equal(root.tag, "{http://www.w3.org/XML/1998/namespace}doc")
    assert_equal(root.get("{http://www.w3.org/XML/1998/namespace}lang"), "en")


def test_xml_prefix_roundtrips_without_declaration() raises:
    var root = fromstring("<r xml:lang='en'><c xml:space='preserve'/></r>")
    var s = tostring(root)
    # Serializes back to the fixed xml: prefix, never re-declaring the URI.
    assert_true('xml:lang="en"' in s)
    assert_false("xmlns" in s)
    var back = fromstring(s.copy())
    assert_equal(back.get("{http://www.w3.org/XML/1998/namespace}lang"), "en")
    assert_equal(
        back.children[0].get("{http://www.w3.org/XML/1998/namespace}space"),
        "preserve",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
