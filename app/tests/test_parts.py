"""Tests for the small pure-Python parts: differ.py, moments.py and timeline.py.

Run from the repository root:
    pytest app/tests/ -v

None of these needs a database.
"""

import re
from datetime import datetime

import moments
from differ import diff_versions
from timeline import HEIGHT, WIDTH, strata, year_bars


# ---------------------------------------------------------------------------
# differ: what changed between two texts
# ---------------------------------------------------------------------------

def test_identical_texts():
    result = diff_versions("one\ntwo", "one\ntwo")
    assert result == {"identical": True, "lines_added": 0, "lines_removed": 0, "hunks": []}


def test_added_line_with_context():
    result = diff_versions("one\nthree", "one\ntwo\nthree")
    assert (result["lines_added"], result["lines_removed"]) == (1, 0)
    assert result["hunks"][0]["rows"] == [("same", "one"), ("added", "two"), ("same", "three")]


def test_removed_line():
    result = diff_versions("one\ntwo\nthree", "one\nthree")
    assert ("removed", "two") in result["hunks"][0]["rows"]
    assert (result["lines_added"], result["lines_removed"]) == (0, 1)


def test_rewritten_line_marks_the_words():
    old = "Jacobs University Bremen is a private university in Bremen."
    new = "Bob the Builder University Bremen is a private university in Bremen."
    kind, marked = diff_versions(old, new)["hunks"][0]["rows"][0]
    assert kind == "changed"
    assert "<del>Jacobs</del>" in marked
    assert "<ins>Bob the Builder</ins>" in marked
    assert "University Bremen is a private university" in marked


def test_completely_different_line_is_shown_as_removed_and_added():
    rows = diff_versions("alpha beta gamma delta", "one two three four five")["hunks"][0]["rows"]
    assert [kind for kind, _ in rows] == ["removed", "added"]


def test_text_is_escaped():
    rows = diff_versions("<b>old</b>", "<script>new</script>")["hunks"][0]["rows"]
    joined = "".join(text for _, text in rows)
    assert "<script" not in joined and "<b>" not in joined
    assert "&lt;" in joined and "&gt;" in joined
    # Whatever tags the result has are the differ's own.
    assert set(re.findall(r"</?(\w+)>", joined)) <= {"del", "ins"}


def test_hunk_says_where_it_is():
    old = "\n".join(f"line {n}" for n in range(1, 21))
    new = old.replace("line 15", "line fifteen")
    hunk = diff_versions(old, new)["hunks"][0]
    assert hunk["line"] == 14          # one line of context before line 15


def test_far_apart_changes_become_separate_hunks():
    old = "\n".join(f"line {n}" for n in range(1, 41))
    new = old.replace("line 3", "line three").replace("line 30", "line thirty")
    assert len(diff_versions(old, new)["hunks"]) == 2


# ---------------------------------------------------------------------------
# moments: reading and writing points in time
# ---------------------------------------------------------------------------

def test_parse_what_a_date_field_sends():
    assert moments.parse_moment("2010-06-01T12:30") == datetime(2010, 6, 1, 12, 30)
    assert moments.parse_moment("2010-06-01T12:30:15") == datetime(2010, 6, 1, 12, 30, 15)


def test_parse_microseconds_and_plain_dates():
    assert moments.parse_moment("2020-01-01T12:00:00.000001") == datetime(2020, 1, 1, 12, 0, 0, 1)
    assert moments.parse_moment("2015-03-04") == datetime(2015, 3, 4)
    assert moments.parse_moment("2009") == datetime(2009, 1, 1)


def test_parse_rejects_nonsense():
    assert moments.parse_moment("") is None
    assert moments.parse_moment(None) is None
    assert moments.parse_moment("yesterday") is None
    assert moments.parse_moment("2010-13-45") is None
    assert moments.parse_moment("'; DROP TABLE article; --") is None


def test_parse_keeps_moments_inside_what_a_timestamp_can_hold():
    assert moments.parse_moment("1066-10-14") == moments.EARLIEST
    assert moments.parse_moment("9999-12-31") == moments.LATEST


def test_url_form_keeps_microseconds_only_when_needed():
    assert moments.for_url(datetime(2010, 6, 1)) == "2010-06-01T00:00:00"
    assert moments.for_url(datetime(2020, 1, 1, 12, 0, 0, 1)) == "2020-01-01T12:00:00.000001"


def test_url_form_reads_back_to_the_same_moment():
    for moment in (datetime(2010, 6, 1, 23, 59, 59), datetime(2020, 1, 1, 12, 0, 0, 1)):
        assert moments.parse_moment(moments.for_url(moment)) == moment


def test_sql_form():
    assert moments.for_sql(datetime(2010, 6, 1, 0, 0, 5)) == "2010-06-01 00:00:05.000000"
    assert moments.for_statement(datetime(2010, 6, 1, 0, 0, 5)) == "2010-06-01 00:00:05"
    assert moments.for_statement(datetime(2010, 6, 1, 0, 0, 5, 999999)) == "2010-06-01 00:00:05.999999"


def test_in_words():
    assert moments.in_words(datetime(2010, 6, 1)) == "1 June 2010, 00:00 UTC"
    assert moments.in_words(datetime(2022, 11, 28, 20, 4, 39)) == "28 November 2022, 20:04:39 UTC"
    assert moments.in_words(datetime(2010, 6, 1), seconds=True) == "1 June 2010, 00:00:00 UTC"


def test_span_in_words():
    start = datetime(2022, 11, 28, 20, 4, 39)
    assert moments.span_in_words(start, datetime(2022, 11, 28, 20, 4, 50)) == "11 seconds"
    assert moments.span_in_words(start, datetime(2022, 11, 28, 20, 5, 39)) == "1 minute"
    assert moments.span_in_words(start, datetime(2022, 12, 1, 20, 4, 39)) == "3 days"
    assert moments.span_in_words(start, datetime(2024, 5, 28, 20, 4, 39)) == "1.5 years"
    assert moments.span_in_words(start, start) == "less than a second"


# ---------------------------------------------------------------------------
# timeline: the picture of an article's life
# ---------------------------------------------------------------------------

POINTS = [(datetime(2010, 1, 1), 100), (datetime(2015, 1, 1), 400), (datetime(2015, 1, 1, 0, 0, 11), 0),
          (datetime(2015, 1, 1, 0, 0, 22), 400)]
START, END = datetime(2010, 1, 1), datetime(2020, 1, 1)


def test_picture_starts_at_the_first_save_and_closes_at_the_right_edge():
    picture = strata(POINTS, START, END)
    assert picture["path"].startswith(f"M0.0,{HEIGHT}V")
    assert picture["path"].endswith(f"H{WIDTH}V{HEIGHT}Z")
    assert picture["largest"] == 400


def test_edits_in_the_same_pixel_become_a_vertical_cut():
    # The blanking at 00:00:11 and its repair 11 seconds later are far less than a
    # pixel apart, so the outline goes straight down and up again without moving right.
    path = strata(POINTS, START, END)["path"]
    assert f"V{float(HEIGHT)}V4.0" in path


def test_needle_follows_the_moment():
    assert strata(POINTS, START, END)["needle"] == WIDTH                      # now: right edge
    assert strata(POINTS, START, END, datetime(2010, 1, 1))["needle"] == 0.0
    assert 495 < strata(POINTS, START, END, datetime(2015, 1, 1))["needle"] < 505
    assert strata(POINTS, START, END, datetime(1999, 1, 1))["needle"] == 0.0   # never off the picture


def test_years_are_marked_inside_the_picture():
    years = strata(POINTS, START, END)["years"]
    assert [label for _, label in years] == ["2011", "2012", "2013", "2014", "2015", "2016",
                                             "2017", "2018", "2019"]
    assert all(0 < x < WIDTH for x, _ in years)


def test_edges_are_given_in_milliseconds_for_the_script():
    picture = strata(POINTS, START, END)
    assert picture["start_ms"] == 1262304000000      # 2010-01-01T00:00:00Z
    assert picture["end_ms"] == 1577836800000        # 2020-01-01T00:00:00Z


def test_year_bars_are_shares_of_the_busiest_year():
    bars = year_bars([{"year": 2002, "edits": 12}, {"year": 2010, "edits": 1188}])
    assert [bar["height"] for bar in bars] == [2, 100]    # a year with edits is never invisible
