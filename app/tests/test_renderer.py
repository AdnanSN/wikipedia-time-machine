"""Tests for app/renderer.py — the wikitext to HTML converter.

Run from the repository root:
    pytest app/tests/ -v

No database is needed; the renderer is a pure Python function.
"""
import sys
from pathlib import Path

# Make sure Python can find renderer.py, which lives in app/.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from renderer import render_wikitext, render_with_notes, _inline


# ---------------------------------------------------------------------------
# Headings
# ---------------------------------------------------------------------------

def test_h2():
    assert render_wikitext("== Introduction ==") == "<h2>Introduction</h2>"


def test_h3():
    assert render_wikitext("=== Early history ===") == "<h3>Early history</h3>"


def test_h4():
    assert render_wikitext("==== Sub-section ====") == "<h4>Sub-section</h4>"


# ---------------------------------------------------------------------------
# Inline markup
# ---------------------------------------------------------------------------

def test_bold():
    result = _inline("'''bold text'''")
    assert "<strong>bold text</strong>" in result


def test_italic():
    result = _inline("''italic text''")
    assert "<em>italic text</em>" in result


def test_bold_italic():
    result = _inline("'''''bold-italic'''''")
    assert "<strong><em>bold-italic</em></strong>" in result


def test_internal_link_with_label():
    result = _inline("[[Python (programming language)|Python]]")
    assert ">Python<" in result
    assert "en.wikipedia.org" in result


def test_internal_link_without_label():
    result = _inline("[[Quantum mechanics]]")
    assert ">Quantum mechanics<" in result


def test_external_link():
    result = _inline("[https://example.com Example site]")
    assert "https://example.com" in result
    assert ">Example site<" in result


def test_template_stripped():
    # Templates we cannot expand; they should disappear, not stay as {{...}}
    result = _inline("{{cite web|url=http://x.com}}")
    assert "{{" not in result


def test_image_stripped():
    result = _inline("[[File:Example.jpg|thumb|Caption]]")
    assert "File:" not in result


# ---------------------------------------------------------------------------
# Block / paragraph
# ---------------------------------------------------------------------------

def test_bullet_list():
    result = render_wikitext("* first item")
    assert "<li>first item</li>" in result


def test_numbered_list():
    result = render_wikitext("# step one")
    assert "<li>step one</li>" in result


def test_plain_paragraph():
    result = render_wikitext("This is a plain sentence.")
    assert "<p>This is a plain sentence.</p>" in result


def test_blank_line_splits_paragraphs():
    result = render_wikitext("First paragraph.\n\nSecond paragraph.")
    assert "<p>First paragraph.</p>" in result
    assert "<p>Second paragraph.</p>" in result


# ---------------------------------------------------------------------------
# The "Constructor University" use-case from the acceptance criteria
# ---------------------------------------------------------------------------

def test_constructor_university_heading():
    """A heading containing 'Constructor University' should render as h2."""
    result = render_wikitext("== Constructor University ==")
    assert "<h2>Constructor University</h2>" in result


# ---------------------------------------------------------------------------
# Safety: old revisions contain vandalism, and none of it may reach the page as HTML
# ---------------------------------------------------------------------------

def test_script_tags_never_survive():
    result = render_wikitext("Hello <script>alert('x')</script> world")
    assert "<script" not in result
    assert "alert" in result            # the words stay, as plain text


def test_angle_brackets_are_escaped():
    result = render_wikitext("if a < b && b > c then <unknown")
    assert "&lt;" in result and "&amp;&amp;" in result
    assert "<unknown" not in result


def test_html_in_a_link_label_is_escaped():
    result = _inline('[[Target|<img src=x onerror=alert(1)>]]')
    assert "<img" not in result


def test_javascript_addresses_are_not_links():
    result = _inline("[javascript:alert(1) click me]")
    assert "<a " not in result


def test_quotes_cannot_break_out_of_an_address():
    result = _inline('[http://example.com/"onmouseover="alert(1) label]')
    assert 'onmouseover="' not in result


def test_null_bytes_cannot_forge_a_placeholder():
    assert "\x00" not in render_wikitext("a\x000\x00b")


# ---------------------------------------------------------------------------
# What is left out, and counted
# ---------------------------------------------------------------------------

def test_nested_templates_are_removed_and_counted():
    text = "Before {{Infobox|name={{PAGENAME}}|x=1}} after {{cn}}."
    result, skipped = render_with_notes(text)
    assert result == "<p>Before  after .</p>"
    assert skipped["templates"] == 2


def test_template_spanning_lines_is_removed():
    text = "{{Infobox university\n| name = IUB\n| city = Bremen\n}}\n'''IUB''' is a university."
    assert render_wikitext(text) == "<p><strong>IUB</strong> is a university.</p>"


def test_unclosed_template_does_not_swallow_the_article():
    result = render_wikitext("Start {{broken template\n\nThe rest of the article.")
    assert "The rest of the article." in result


def test_footnotes_are_removed_and_counted():
    text = 'Fact.<ref>Source one</ref> More.<ref name="a" /> End.<ref name="b">Two</ref>'
    result, skipped = render_with_notes(text)
    assert "Source" not in result and "Two" not in result
    assert skipped["footnotes"] == 3


def test_table_is_removed_and_counted():
    text = "Above.\n{| class=\"wikitable\"\n! A !! B\n|-\n| 1 || 2\n|}\nBelow."
    result, skipped = render_with_notes(text)
    assert "wikitable" not in result and "Above." in result and "Below." in result
    assert skipped["tables"] == 1


def test_image_with_a_link_in_its_caption_is_removed():
    text = "[[File:Campus.jpg|thumb|The campus in [[Bremen]], 2005]]Text after."
    result, skipped = render_with_notes(text)
    assert result == "<p>Text after.</p>"
    assert skipped["images"] == 1


def test_categories_and_other_languages_are_removed():
    result = render_wikitext("Text.\n[[Category:Universities]]\n[[de:Jacobs University]]")
    assert result == "<p>Text.</p>"


def test_comments_are_removed():
    assert render_wikitext("Seen<!-- not seen -->.") == "<p>Seen.</p>"


# ---------------------------------------------------------------------------
# Links
# ---------------------------------------------------------------------------

def test_link_to_an_article_we_have_stays_in_the_time_machine():
    def link_for(title):
        return "/article/7?at=2010-01-01T00:00:00" if title == "InnoDB" else None

    result = _inline("uses [[InnoDB]] and [[MyISAM]]", link_for)
    assert '<a class="local" href="/article/7?at=2010-01-01T00:00:00">InnoDB</a>' in result
    assert 'href="https://en.wikipedia.org/wiki/MyISAM"' in result


def test_link_titles_ignore_first_letter_case_and_underscores():
    seen = []
    _inline("[[temporal_database|temporal]]", lambda title: seen.append(title))
    assert seen == ["Temporal database"]


def test_link_trail_joins_the_label():
    assert ">transactions</a>" in _inline("[[transaction]]s")


def test_pipe_trick_drops_the_bracketed_part():
    assert ">Aria</a>" in _inline("[[Aria (storage engine)|]]")


def test_apostrophe_in_a_title_does_not_start_italics():
    result = _inline("[[Codd's 12 rules]] and ''italic''")
    assert "Codd%27s_12_rules" in result
    assert "<em>italic</em>" in result


# ---------------------------------------------------------------------------
# Blocks
# ---------------------------------------------------------------------------

def test_list_items_share_one_list():
    assert render_wikitext("* one\n* two") == "<ul><li>one</li><li>two</li></ul>"


def test_nested_list():
    result = render_wikitext("* one\n** inner\n* two")
    assert result == "<ul><li>one\n<ul><li>inner</li></ul></li><li>two</li></ul>"


def test_numbered_list_uses_ol():
    assert render_wikitext("# first\n# second") == "<ol><li>first</li><li>second</li></ol>"


def test_definition_list():
    assert render_wikitext("; Term\n: Meaning") == "<dl><dt>Term</dt>\n<dd>Meaning</dd></dl>"


def test_code_sample_is_kept_exactly_and_escaped():
    text = 'Before.\n<syntaxhighlight lang="sql">\nSELECT * FROM t WHERE a < 1;\n</syntaxhighlight>\nAfter.'
    result = render_wikitext(text)
    assert "<pre>SELECT * FROM t WHERE a &lt; 1;</pre>" in result
    assert "<p>Before.</p>" in result and "<p>After.</p>" in result


def test_nowiki_text_is_not_treated_as_markup():
    assert render_wikitext("<nowiki>'''not bold'''</nowiki>") == "<p>'''not bold'''</p>"


def test_lines_of_one_paragraph_are_joined():
    assert render_wikitext("One line\nand the next.") == "<p>One line and the next.</p>"


def test_horizontal_rule():
    assert "<hr>" in render_wikitext("Above\n----\nBelow")
