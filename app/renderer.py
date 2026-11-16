"""wikitext -> simple, safe HTML for the time machine page.

Wikipedia stores articles as wikitext. Rendering it exactly needs MediaWiki itself,
with every template as it was on that day, so this renderer aims lower: the text an
editor wrote, readable, at any moment in the article's history.

What it renders: headings, paragraphs, bold and italics, links (to other articles in our
data set at the same moment, otherwise to Wikipedia), external links, bullet and
numbered lists, definition lists, and code samples.

What it leaves out, and counts so the page can say so: templates ({{...}}, which
includes infoboxes and citations), tables ({| ... |}), footnotes (<ref>) and images.

Safety: old revisions contain vandalism, including HTML and scripts. Every piece of
article text is HTML-escaped before any markup is added, and the only tags in the
output are the ones written in this file. Links only ever point to http(s) addresses.
"""

import html
import re
from urllib.parse import quote

WIKIPEDIA = "https://en.wikipedia.org/wiki/"

_COMMENT = re.compile(r"<!--.*?-->", re.S)
_REF_SINGLE = re.compile(r"<ref\b[^>]*?/\s*>", re.I)
_REF_PAIR = re.compile(r"<ref\b[^>]*>.*?</ref\s*>", re.S | re.I)
_NOT_SHOWN = re.compile(r"<(gallery|timeline|imagemap|math|chem|score|templatestyles)\b[^>]*>.*?</\1\s*>",
                        re.S | re.I)
_CODE_BLOCK = re.compile(r"<(syntaxhighlight|source|pre)\b[^>]*>(.*?)</\1\s*>", re.S | re.I)
_NOWIKI = re.compile(r"<nowiki\b[^>]*>(.*?)</nowiki\s*>", re.S | re.I)
_BREAK = re.compile(r"<br\s*/?\s*>", re.I)
_TAG = re.compile(r"</?[a-zA-Z][^<>]*>")
_FILE_START = re.compile(r"\[\[\s*(?:File|Image|Media)\s*:", re.I)
_CATEGORY = re.compile(r"\[\[\s*Category\s*:[^\[\]]*\]\]\n?", re.I)
_OTHER_LANGUAGE = re.compile(r"\[\[[a-z]{2,3}(?:-[a-z]+)*:[^\[\]|]*\]\]\n?")
_HEADING = re.compile(r"(={2,6})\s*(.+?)\s*\1\s*")
_LIST_PREFIX = re.compile(r"[*#][*#:]*")
# [[target|label]]trail   or   [https://address label]
_LINK = re.compile(r"\[\[([^\[\]|]+)(?:\|([^\[\]]*))?\]\]([a-zA-Z]*)"
                   r"|\[(https?://[^\s\[\]]+)(?:\s+([^\[\]]*))?\]")
# Stand-ins for pieces that must survive the escaping untouched: B for a block of its
# own (a code sample), I for a piece inside a line. \x00 cannot occur in the text,
# because it is removed first.
_HELD = re.compile("\x00[BI](\\d+)\x00")
_HELD_BLOCK = re.compile("\x00B\\d+\x00")


def render_wikitext(text, link_for=None):
    """wikitext -> HTML. See render_with_notes for the arguments."""
    return render_with_notes(text, link_for)[0]


def render_with_notes(text, link_for=None):
    """Return (html, skipped), where skipped counts what was left out.

    `link_for` is an optional function: given an article title, it returns the address
    of that article inside the time machine, or None if we do not have the article.
    """
    skipped = {"templates": 0, "tables": 0, "footnotes": 0, "images": 0}
    held = []  # ready-made HTML for the stand-ins

    def hold(piece_of_html, kind="I"):
        held.append(piece_of_html)
        return f"\x00{kind}{len(held) - 1}\x00"

    text = text.replace("\x00", "").replace("\r\n", "\n")
    text = _COMMENT.sub("", text)

    # Code samples and <nowiki> keep their text exactly, so take them out first.
    text = _CODE_BLOCK.sub(
        lambda m: "\n" + hold("<pre>" + html.escape(m.group(2).strip("\n"), quote=False) + "</pre>", "B") + "\n",
        text)
    text = _NOWIKI.sub(lambda m: hold(html.escape(m.group(1), quote=False)), text)

    text, count = _REF_SINGLE.subn("", text)
    skipped["footnotes"] += count
    text, count = _REF_PAIR.subn("", text)
    skipped["footnotes"] += count
    text = _NOT_SHOWN.sub("", text)

    text, skipped["templates"] = _drop_balanced(text, "{{", "}}")
    text, skipped["tables"] = _drop_tables(text)
    text, skipped["images"] = _drop_files(text)
    text = _CATEGORY.sub("", text)
    text = _OTHER_LANGUAGE.sub("", text)

    text = _BREAK.sub(lambda m: hold("<br>"), text)
    text = _TAG.sub("", text)  # any other tag: keep what is inside it, drop the tag

    body = _blocks(text, link_for)
    return _HELD.sub(lambda m: held[int(m.group(1))], body), skipped


# ---------------------------------------------------------------------------
# Pieces that are left out
# ---------------------------------------------------------------------------

def _drop_balanced(text, opener, closer):
    """Remove every opener ... closer span, including spans nested inside one another.

    Returns (text, how many outermost spans were removed). A span that is never closed
    is kept as it is, so a broken template cannot swallow the rest of the article.
    """
    token = re.compile(re.escape(opener) + "|" + re.escape(closer))
    kept, depth, count, resume_at, opened_at = [], 0, 0, 0, 0
    for match in token.finditer(text):
        if match.group() == opener:
            if depth == 0:
                kept.append(text[resume_at:match.start()])
                opened_at = match.start()
                count += 1
            depth += 1
        elif depth:
            depth -= 1
            if depth == 0:
                resume_at = match.end()
    if depth:
        kept.append(text[opened_at:])
        count -= 1
    else:
        kept.append(text[resume_at:])
    return "".join(kept), count


def _drop_tables(text):
    """Remove {| ... |} tables, which start and end at the beginning of a line."""
    kept, depth, count = [], 0, 0
    for line in text.split("\n"):
        start = line.lstrip()
        if start.startswith("{|"):
            depth += 1
            count += depth == 1
        elif depth:
            if start.startswith("|}"):
                depth -= 1
        else:
            kept.append(line)
    if depth:  # a table that never closes: show the text as it is rather than hide it
        return text, 0
    return "\n".join(kept), count


def _drop_files(text):
    """Remove [[File:...]] and [[Image:...]]. Their captions may contain links."""
    kept, count, position = [], 0, 0
    while True:
        match = _FILE_START.search(text, position)
        if not match:
            break
        depth, cursor = 1, match.end()
        while depth and cursor < len(text):
            opening = text.find("[[", cursor)
            closing = text.find("]]", cursor)
            if closing == -1:
                cursor = len(text)
                break
            if opening != -1 and opening < closing:
                depth, cursor = depth + 1, opening + 2
            else:
                depth, cursor = depth - 1, closing + 2
        if depth:  # never closed: leave the rest alone
            break
        kept.append(text[position:match.start()])
        position = cursor
        count += 1
    kept.append(text[position:])
    return "".join(kept), count


# ---------------------------------------------------------------------------
# Blocks: headings, lists, code, paragraphs
# ---------------------------------------------------------------------------

def _blocks(text, link_for):
    out = []          # finished pieces of HTML
    paragraph = []    # lines of the paragraph being collected
    open_lists = []   # the list tags that are open now, outermost first
    indented = []     # lines of a block that starts with a space (shown as written)

    def end_paragraph():
        if paragraph:
            out.append("<p>" + " ".join(paragraph) + "</p>")
            paragraph.clear()

    def end_lists(keep=0):
        while len(open_lists) > keep:
            out.append(f"</li></{open_lists.pop()}>")

    def end_indented():
        if indented:
            out.append("<pre>" + "\n".join(indented) + "</pre>")
            indented.clear()

    def end_all():
        end_paragraph()
        end_lists()
        end_indented()

    for line in text.split("\n"):
        heading = _HEADING.fullmatch(line)
        prefix = _LIST_PREFIX.match(line)

        if heading:
            end_all()
            level = len(heading.group(1))
            out.append(f"<h{level}>{_inline(heading.group(2), link_for)}</h{level}>")
        elif prefix:
            end_paragraph()
            end_indented()
            kinds = ["ol" if mark == "#" else "ul" for mark in prefix.group()]
            same = 0
            while same < min(len(kinds), len(open_lists)) and kinds[same] == open_lists[same]:
                same += 1
            end_lists(keep=same)
            if same == len(kinds):
                out.append("</li><li>")          # next item of the same list
            for kind in kinds[same:]:
                out.append(f"<{kind}><li>")      # a new or deeper list
                open_lists.append(kind)
            out.append(_inline(line[prefix.end():].strip(), link_for))
        elif line.startswith((":", ";")):
            end_all()
            tag = "dt" if line[0] == ";" else "dd"
            out.append(f"<dl><{tag}>{_inline(line.lstrip(':;').strip(), link_for)}</{tag}></dl>")
        elif line.strip() == "----":
            end_all()
            out.append("<hr>")
        elif line.strip() == "":
            end_all()
        elif _HELD_BLOCK.fullmatch(line.strip()):
            end_all()
            out.append(line.strip())             # a code sample held earlier
        elif line.startswith(" "):
            end_paragraph()
            end_lists()
            indented.append(_inline(line[1:], link_for))
        else:
            end_lists()
            end_indented()
            paragraph.append(_inline(line.strip(), link_for))
    end_all()
    body = "\n".join(out)
    # A list item and its text belong on one line: <li>text</li>.
    body = body.replace("<li>\n", "<li>").replace("\n</li>", "</li>")
    # Adjacent one-line definition lists read better as one list.
    return body.replace("</dl>\n<dl>", "\n")


# ---------------------------------------------------------------------------
# Inline markup: links, bold, italics
# ---------------------------------------------------------------------------

def _inline(text, link_for=None):
    """One line of wikitext -> HTML. The text is escaped; only our own tags are added."""
    # A no-op inside render_with_notes, which removed these already. Kept so that the
    # function is safe to call on its own.
    text = _drop_balanced(text, "{{", "}}")[0]
    text = _drop_files(text)[0]

    pieces, position = [], 0
    for match in _LINK.finditer(text):
        pieces.append(html.escape(text[position:match.start()], quote=False))
        if match.group(4):
            pieces.append(_external_link(match.group(4), match.group(5)))
        else:
            pieces.append(_wiki_link(match.group(1), match.group(2), match.group(3), link_for))
        position = match.end()
    pieces.append(html.escape(text[position:], quote=False))
    text = "".join(pieces)

    # Longest first, so that ''''' is not read as ''' followed by ''.
    text = re.sub(r"'''''(.+?)'''''", r"<strong><em>\1</em></strong>", text)
    text = re.sub(r"'''(.+?)'''", r"<strong>\1</strong>", text)
    text = re.sub(r"''(.+?)''", r"<em>\1</em>", text)
    return text


def _wiki_link(target, label, trail, link_for):
    """[[target|label]]trail -> a link into the time machine, or to Wikipedia."""
    target = target.strip().lstrip(":").strip()
    if label is None:
        label = target
    elif label.strip() == "":
        label = re.sub(r"\s*\([^()]*\)$", "", target)   # [[Aria (storage engine)|]] -> Aria
    label = html.escape(label.strip() + trail, quote=False)
    if target.startswith("#") or not target:
        return label.lstrip("#")                         # a link within the same page

    title = title_key(target.split("#")[0])
    local = link_for(title) if link_for else None
    if local:
        return f'<a class="local" href="{html.escape(local, quote=True)}">{label}</a>'
    # quote() also encodes apostrophes, so an address can never look like '' markup.
    address = WIKIPEDIA + quote(target.replace(" ", "_"), safe="/:#(),")
    return f'<a class="wikipedia" href="{address}">{label}</a>'


def _external_link(address, label):
    label = html.escape(label.strip(), quote=False) if label and label.strip() else \
        html.escape(address, quote=False)
    # quote() leaves a valid address unchanged and encodes quotes and apostrophes.
    address = html.escape(quote(address, safe=":/?#[]@!$&()*+,;=%~._-"), quote=True)
    return f'<a class="external" href="{address}" rel="nofollow noopener">{label}</a>'


def title_key(title):
    """How MediaWiki compares titles: underscores are spaces, the first letter is upper case."""
    title = " ".join(title.replace("_", " ").split())
    return title[:1].upper() + title[1:]
