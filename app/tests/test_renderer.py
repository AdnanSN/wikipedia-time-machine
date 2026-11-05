"""Tests for app/renderer.py — the wikitext to HTML converter.

Run from the repository root:
    pytest app/tests/ -v

No database is needed; the renderer is a pure Python function.
"""
import sys
from pathlib import Path

# Make sure Python can find renderer.py, which lives in app/.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from renderer import render_wikitext, _inline


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
