"""mojo-xml: general-purpose XML parsing for Mojo (an ElementTree-shaped API)."""

from xml.pull import (
    XmlPullParser,
    XmlEvent,
    normalize_encoding,
    normalize_encoding_bytes,
    EVENT_START,
    EVENT_END,
    EVENT_TEXT,
    EVENT_EOF,
)
from xml.etree import (
    Element,
    fromstring,
    tostring,
    SubElement,
)
