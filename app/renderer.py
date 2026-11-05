"""wikitext → simple HTML renderer for the Wikipedia Time Machine app.

Converts the subset of wikitext that is most common in our 30 articles.
What we handle: section headings, bold, italic, internal links, external
links, bullet lists, numbered lists, and plain paragraphs.

What we deliberately skip: templates ({{...}}), tables ({|...|}}), HTML
tags already in the source, <ref> footnotes, and images ([[File:...]]).
The article page tells the reader this in a note.  Skipping these keeps the
renderer small enough that every line can be explained in a presentation.
"""

import re


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def render_wikitext(text: str) -> str:
    """Convert wikitext string to a safe HTML string.

    The function works line by line for block-level elements (headings,
    lists, paragraphs) and then applies inline markup to each line.
    """
    lines = text.splitlines()
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]

        # --- Section headings: ====, ===, ==  (check longest first) ---
        # Wikitext uses == Title == for h2, === for h3, ==== for h4.
        m = re.fullmatch(r"(={2,6})\s*(.+?)\s*\1", line)
        if m:
            level = len(m.group(1))        # number of = signs → h-level
            inner = _inline(m.group(2))
            out.append(f"<h{level}>{inner}</h{level}>")
            i += 1
            continue

        # --- Bullet list item: starts with * ---
        if line.startswith("*"):
            depth = len(line) - len(line.lstrip("*"))
            content = _inline(line.lstrip("*").strip())
            out.append(f"<li>{content}</li>")
            i += 1
            continue

        # --- Numbered list item: starts with # ---
        if line.startswith("#"):
            content = _inline(line.lstrip("#").strip())
            out.append(f"<li>{content}</li>")
            i += 1
            continue

        # --- Blank line: paragraph break ---
        if line.strip() == "":
            out.append("")   # blank lines separate paragraphs
            i += 1
            continue

        # --- Everything else is a paragraph line ---
        out.append(_inline(line))
        i += 1

    # Join, then wrap runs of non-empty, non-tag lines in <p>...</p>.
    return _wrap_paragraphs("\n".join(out))


# ---------------------------------------------------------------------------
# Inline markup (applied to individual lines)
# ---------------------------------------------------------------------------

def _inline(text: str) -> str:
    """Apply inline wikitext rules to a single line of text.

    Rules applied in order (order matters to avoid double-substitution):
    1. Strip template calls {{...}} — we cannot expand them.
    2. Internal links: [[Article|Display]] or [[Article]]
    3. External links: [http://... Display text]
    4. Bold+italic combined: '''''text'''''
    5. Bold: '''text'''
    6. Italic: ''text''
    """
    # 1. Remove templates — just drop them so they don't show as raw {{...}}
    text = re.sub(r"\{\{[^}]*\}\}", "", text)

    # 2a. [[File:...]] or [[Image:...]] — skip entirely
    text = re.sub(r"\[\[(?:File|Image):[^\]]*\]\]", "", text, flags=re.IGNORECASE)

    # 2b. Internal wikilinks [[Target|Label]] → <a>Label</a>
    def internal_link(m):
        parts = m.group(1).split("|", 1)
        label = _esc(parts[1] if len(parts) == 2 else parts[0])
        target = _esc(parts[0].replace(" ", "_"))
        return f'<a href="https://en.wikipedia.org/wiki/{target}">{label}</a>'
    text = re.sub(r"\[\[([^\]]+)\]\]", internal_link, text)

    # 3. External links [url label]
    def external_link(m):
        url = _esc(m.group(1))
        label = _esc(m.group(2).strip()) if m.group(2).strip() else url
        return f'<a href="{url}">{label}</a>'
    text = re.sub(r"\[(\S+)\s*(.*?)\]", external_link, text)

    # 4. Bold + italic combined '''''text'''''
    text = re.sub(r"'''''(.+?)'''''", r"<strong><em>\1</em></strong>", text)

    # 5. Bold '''text'''
    text = re.sub(r"'''(.+?)'''", r"<strong>\1</strong>", text)

    # 6. Italic ''text''
    text = re.sub(r"''(.+?)''", r"<em>\1</em>", text)

    return text


def _esc(text: str) -> str:
    """Minimal HTML-escape for text that goes into attributes or content."""
    return (text
            .replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace('"', "&quot;"))


# ---------------------------------------------------------------------------
# Paragraph wrapping
# ---------------------------------------------------------------------------

def _wrap_paragraphs(html: str) -> str:
    """Group consecutive non-empty lines that aren't already block tags into <p>.</p>.

    Lines that start with < are already block elements (h2, li, etc.) and
    should not be wrapped again.
    """
    result = []
    para_lines = []

    def flush_para():
        if para_lines:
            result.append("<p>" + " ".join(para_lines) + "</p>")
            para_lines.clear()

    for line in html.splitlines():
        stripped = line.strip()
        if stripped == "":
            flush_para()
        elif stripped.startswith("<"):
            # Already a block element — flush any pending paragraph first.
            flush_para()
            result.append(stripped)
        else:
            para_lines.append(stripped)

    flush_para()
    return "\n".join(result)
