"""Parse a small inline SVG document and print its structure.

Run it with the pixi demo task:

    pixi run demo

or directly:

    mojo run -I src examples/parse_svg.mojo
"""

from xml.etree import Element, fromstring, tostring


def main() raises:
    var svg: String = (
        "<svg xmlns='http://www.w3.org/2000/svg' width='120' height='60'>"
        "  <rect x='0' y='0' width='120' height='60' fill='#0b7285'/>"
        "  <circle cx='60' cy='30' r='20' fill='#ffd43b'/>"
        "  <text x='60' y='34' text-anchor='middle'>mojo-xml</text>"
        "</svg>"
    )

    var root = fromstring(svg^)

    # The default xmlns puts every element in the SVG namespace, so tags
    # come back in Clark notation: {http://www.w3.org/2000/svg}svg, etc.
    print("root tag:      ", root.tag)
    print("canvas size:   ", root.get("width"), "x", root.get("height"))
    print("child count:   ", len(root))
    print()

    # Walk the direct children and show each tag plus one attribute.
    print("shapes:")
    for ref child in root.children:
        # iter("") over a single element list keeps the demo simple; here
        # we just read fields directly.
        if child.get("fill") != "":
            print("  -", child.tag, "fill=", child.get("fill"))
        else:
            print("  -", child.tag, "(no fill)")
    print()

    # find / findtext with a Clark-notation path.
    var label = root.findtext("{http://www.w3.org/2000/svg}text")
    print("text label:    ", label)

    # iter() gives a depth-first view of the whole tree.
    print("all elements:  ", len(root.iter()), "total")

    # Round-trip back to XML text.
    print()
    print("re-serialized:")
    print(tostring(root))
