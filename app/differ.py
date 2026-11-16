"""The difference between two versions of an article, ready to show (milestone M6).

The database hands us the two texts, each read with FOR SYSTEM_TIME AS OF. Comparing
them is ordinary text work, done with Python's difflib:

1. compare the texts line by line (in wikitext a paragraph is one line), and keep only
   the changed lines plus a little unchanged text around them;
2. where a line was rewritten rather than added or removed, compare the old and the new
   line word by word, so the page can mark the words that changed.

Everything is HTML-escaped here, because old revisions may contain anything.
"""

import difflib
import html
import re

# Words, runs of spaces, and single punctuation marks.
_WORDS = re.compile(r"\s+|\w+|[^\w\s]")

# Comparing word by word costs time in proportion to old words x new words.
# Past this size a rewritten passage is shown as removed lines and added lines.
_WORD_DIFF_LIMIT = 4_000_000
# If less than this share of the words survived, marking words only adds noise.
_REWRITE_RATIO = 0.35


def diff_versions(old_text, new_text, context=1):
    """Compare two texts.

    Returns a dictionary:
      identical      True if nothing changed
      lines_added    how many lines exist only in the new text
      lines_removed  how many lines exist only in the old text
      hunks          the changed places, each {"line": n, "rows": [(kind, html), ...]},
                     where kind is "same", "removed", "added" or "changed"
    """
    old_lines = old_text.split("\n")
    new_lines = new_text.split("\n")
    matcher = difflib.SequenceMatcher(None, old_lines, new_lines, autojunk=False)

    hunks, added, removed = [], 0, 0
    for group in matcher.get_grouped_opcodes(context):
        rows = []
        for kind, old_from, old_to, new_from, new_to in group:
            old_part = old_lines[old_from:old_to]
            new_part = new_lines[new_from:new_to]
            if kind == "equal":
                rows += [("same", _escape(line)) for line in old_part]
                continue
            removed += len(old_part)
            added += len(new_part)
            if kind == "replace":
                marked = _mark_words("\n".join(old_part), "\n".join(new_part))
                if marked is not None:
                    rows.append(("changed", marked))
                    continue
            rows += [("removed", _escape(line)) for line in old_part]
            rows += [("added", _escape(line)) for line in new_part]
        hunks.append({"line": group[0][3] + 1, "rows": rows})

    return {"identical": not hunks, "lines_added": added, "lines_removed": removed,
            "hunks": hunks}


def _mark_words(old, new):
    """One passage with the removed words in <del> and the added words in <ins>.

    Returns None when the passage was rewritten so thoroughly, or is so long, that the
    caller should show it as removed and added lines instead.
    """
    old_words = _WORDS.findall(old)
    new_words = _WORDS.findall(new)
    if len(old_words) * len(new_words) > _WORD_DIFF_LIMIT:
        return None
    # How much survived is judged on the words alone: any two sentences share their spaces.
    old_solid = [word for word in old_words if not word.isspace()]
    new_solid = [word for word in new_words if not word.isspace()]
    if difflib.SequenceMatcher(None, old_solid, new_solid, autojunk=False).ratio() < _REWRITE_RATIO:
        return None
    matcher = difflib.SequenceMatcher(None, old_words, new_words, autojunk=False)
    pieces = []
    for kind, old_from, old_to, new_from, new_to in matcher.get_opcodes():
        before = _escape("".join(old_words[old_from:old_to]))
        after = _escape("".join(new_words[new_from:new_to]))
        if kind == "equal":
            pieces.append(before)
        else:
            if before:
                pieces.append(f"<del>{before}</del>")
            if after:
                pieces.append(f"<ins>{after}</ins>")
    return "".join(pieces)


def _escape(text):
    return html.escape(text, quote=False)
