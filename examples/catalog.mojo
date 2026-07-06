"""A small ElementTree-shaped demo: parse a catalog, query it, serialize it.

Run: mojo run -I src examples/catalog.mojo
"""
from xml import fromstring, tostring, Element, SubElement


def main() raises:
    var doc = fromstring(
        String(
            "<catalog><book id='b1'><title>Mojo in"
            " Practice</title><author>Modular</author></book><book"
            " id='b2'><title>Systems"
            " Mojo</title><author>Corner</author></book></catalog>"
        )
    )

    print("root:", doc.tag, "|", len(doc), "children")

    # find / get / findtext — the ElementTree API Python devs already know
    for book in doc.findall("book"):
        print(
            "  ",
            book.get("id"),
            "->",
            book.findtext("title"),
            "by",
            book.findtext("author"),
        )

    # iter() walks the whole tree depth-first
    print("titles:", end=" ")
    for t in doc.iter("title"):
        print(t.text, end="  ")
    print()

    # build a tree and serialize it back to XML
    var out = Element(String("shelf"))
    var b = Element(String("book"))
    b.set("id", "b3")
    out.append(b^)
    print("built:", tostring(out))
