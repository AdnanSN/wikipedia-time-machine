"""Tests of the pages themselves, against the built database.

Run from the repository root, with MariaDB running and the database built:
    pytest app/tests/ -v

Each test gets a database connection inside a transaction that is rolled back afterwards
(see conftest.py), so the lab tests may edit and delete freely. Without a reachable
database these tests are skipped and say why.

The numbers and names below (1,007 versions, the vandal edit of 28 November 2022, ...)
are facts of the committed data set, which never changes: it ends at 2026-11-01.
"""

import re

CU = 104185           # Constructor University
MARIADB = 24960699    # MariaDB
LAB_NOTES = 1         # the demo page made by sql/04_lab.sql


def body_of(response):
    """The page's HTML, with line breaks and indentation reduced to single spaces."""
    return re.sub(r"\s+", " ", response.get_data(as_text=True))


def form_token(client, path):
    """The hidden token from one of the lab's forms."""
    return re.search(r'name="form_token" value="([^"]+)"', body_of(client.get(path))).group(1)


def lab_versions(client, page_id=LAB_NOTES):
    return client.db.one("SELECT COUNT(*) AS n FROM lab_page FOR SYSTEM_TIME ALL WHERE page_id = %s",
                         (page_id,))["n"]


def lab_text(client, page_id=LAB_NOTES):
    row = client.db.one("SELECT content FROM lab_page WHERE page_id = %s", (page_id,))
    return row["content"] if row else None


# ---------------------------------------------------------------------------
# The front page: every article at one moment
# ---------------------------------------------------------------------------

def test_front_page_lists_every_article(client):
    page = client.get("/")
    assert page.status_code == 200
    assert "30 Wikipedia articles" in body_of(page)
    assert body_of(page).count('<th scope="row"><a href="/article/') == 30


def test_front_page_travels_with_one_set_statement(client):
    body = body_of(client.get("/?at=2005-01-01T00:00:00"))
    assert "14 of 30 Wikipedia articles existed" in body
    assert body.count('<th scope="row"><a href="/article/') == 14
    assert "Not written yet at that moment" in body
    # The page prints the statements it ran, and these two did the travelling.
    statements = [entry["sql"] for entry in client.db.log]
    assert statements[0] == "SET system_versioning_asof = '2005-01-01 00:00:00.000000'"
    assert "FOR SYSTEM_TIME" not in statements[1] and "FROM article" in statements[1]


def test_travelling_does_not_leak_into_the_next_request(client):
    client.get("/?at=2005-01-01T00:00:00")
    assert body_of(client.get("/")).count('<th scope="row"><a href="/article/') == 30


# ---------------------------------------------------------------------------
# One article at one moment
# ---------------------------------------------------------------------------

def test_constructor_university_in_2005_and_today(client):
    """The acceptance test of milestone M2 in docs/PLAN.md."""
    then = body_of(client.get(f"/article/{CU}?at=2005-01-01T00:00:00"))
    assert "<strong>International University Bremen</strong>" in then
    assert "FOR SYSTEM_TIME AS OF TIMESTAMP &#39;2005-01-01 00:00:00.000000&#39;" in then
    now = body_of(client.get(f"/article/{CU}"))
    assert "<strong>Constructor University</strong>" in now


def test_the_page_shows_the_row_the_table_returns(client):
    row = client.db.one("""
        SELECT rev_id, len FROM article FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00'
        WHERE page_id = %s""", (MARIADB,))
    body = body_of(client.get(f"/article/{MARIADB}?at=2010-06-01T00:00:00"))
    assert row["rev_id"] == 365034244
    assert f"oldid={row['rev_id']}" in body
    assert f"{row['len']:,} bytes" in body


def test_vandalism_that_stood_for_eleven_seconds(client):
    body = body_of(client.get(f"/article/{CU}?at=2022-11-28T20:04:45"))
    assert "<strong>Bob the Builder University Bremen</strong>" in body
    assert "11 seconds" in body
    assert "Wikipedia marks this edit as reverted" in body


def test_previous_and_next_edit_step_exactly_one_version(client):
    body = body_of(client.get(f"/article/{CU}?at=2022-11-28T20:04:45"))
    assert 'rel="prev" href="/article/104185?at=2022-11-27T00:45:18"' in body
    assert 'rel="next" href="/article/104185?at=2022-11-28T20:04:50"' in body


def test_first_version_has_no_previous_edit_and_the_current_one_no_next(client):
    first = body_of(client.get(f"/article/{MARIADB}?at=2009-11-04T15:49:24"))
    assert 'rel="prev"' not in first and 'rel="next"' in first
    current = body_of(client.get(f"/article/{MARIADB}"))
    assert 'rel="next"' not in current and "Still the current text" in current


def test_links_between_our_articles_stay_in_the_same_moment(client):
    body = body_of(client.get(f"/article/{MARIADB}?at=2015-01-01T00:00:00"))
    assert re.search(r'<a class="local" href="/article/\d+\?at=2015-01-01T00:00:00">', body)


def test_before_the_article_existed(client):
    page = client.get(f"/article/{MARIADB}?at=2001-01-01T00:00:00")
    assert page.status_code == 404
    assert "had not been written yet" in body_of(page)
    assert "at=2009-11-04T15:49:24" in body_of(page)      # the way to its first version


def test_unknown_article_and_unknown_address(client):
    assert client.get("/article/999").status_code == 404
    assert client.get("/no/such/page").status_code == 404


def test_a_moment_that_is_not_a_date_means_now(client):
    body = body_of(client.get(f"/article/{MARIADB}?at=%27%3B+DROP+TABLE+article%3B+--"))
    assert "as it stands now" in body


def test_wikitext_view_shows_the_source_escaped(client):
    body = body_of(client.get(f"/article/{CU}?at=2005-01-01T00:00:00&view=source"))
    assert '<pre class="wikitext">' in body
    assert "&#39;&#39;&#39;International University Bremen&#39;&#39;&#39;" in body


# ---------------------------------------------------------------------------
# History, diff, phrase, search, about
# ---------------------------------------------------------------------------

def test_history_is_paged_newest_first(client):
    body = body_of(client.get(f"/article/{CU}/history"))
    assert "1,007 versions" in body and "Page 1 of 11" in body
    assert body.count('name="to"') == 100
    last = body_of(client.get(f"/article/{CU}/history?page=11"))
    assert last.count('name="to"') == 7
    assert "2002-10-14 17:40:01" in last              # the first save, at the bottom


def test_diff_shows_what_the_vandal_changed(client):
    body = body_of(client.get(f"/article/{CU}/diff?to=2022-11-28T20:04:39"))
    assert "<del>Jacobs</del><ins>Bob the Builder</ins> University Bremen" in body
    assert "over 1 save" in body
    # Both texts came from one statement with two moments in it.
    assert any(entry["sql"].count("FOR SYSTEM_TIME AS OF") == 2 for entry in client.db.log)


def test_diff_counts_the_saves_in_between(client):
    saves = client.db.one("""
        SELECT COUNT(*) AS n FROM article FOR SYSTEM_TIME ALL
        WHERE page_id = %s AND row_start > '2005-01-01' AND row_start <= '2010-01-01'""", (CU,))["n"]
    body = body_of(client.get(f"/article/{CU}/diff?from=2005-01-01&to=2010-01-01"))
    assert f"over {saves:,} saves" in body


def test_diff_puts_two_moments_in_order_and_notices_no_change(client):
    swapped = body_of(client.get(f"/article/{CU}/diff?from=2010-01-01&to=2005-01-01"))
    assert swapped.index("1 January 2005") < swapped.index("1 January 2010")
    same = body_of(client.get(f"/article/{CU}/diff?from=2022-11-28T20:04:40&to=2022-11-28T20:04:45"))
    assert "The same version was current at both moments" in same


def test_diff_from_before_the_article_existed(client):
    assert client.get(f"/article/{MARIADB}/diff?from=2001-01-01&to=2015-01-01").status_code == 404


def test_phrase_finds_the_periods_and_the_editors(client):
    body = body_of(client.get(f"/article/{CU}/phrase?q=Jacobs+University+Bremen"))
    assert "during 4 periods" in body
    assert "lets maybe wait till the press conference" in body      # the first, 3-minute, period


def test_phrase_treats_wildcards_as_ordinary_characters(client):
    # With % as a wildcard this would match every version.
    body = body_of(client.get(f"/article/{CU}/phrase?q=%25%25"))
    assert "No version of this article has ever contained" in body


def test_search_then_and_ever(client):
    said_then = client.db.one("""
        SELECT COUNT(*) AS n FROM article FOR SYSTEM_TIME AS OF TIMESTAMP '2009-06-01 00:00:00'
        WHERE content LIKE '%%MariaDB%%'""")["n"]
    body = body_of(client.get("/search?q=MariaDB&at=2009-06-01T00:00:00"))
    assert said_then == 1                                           # only its creator's article
    assert "Michael Widenius" in body
    assert "22 March 2009" in body                                  # when that article first said it


def test_about_shows_the_table_as_the_server_describes_it(client):
    body = body_of(client.get("/about"))
    assert "WITH SYSTEM VERSIONING" in body and "PERIOD FOR SYSTEM_TIME" in body
    assert "PRIMARY KEY (`page_id`,`row_end`)" in body              # the server added row_end


def test_no_page_reads_the_revision_table(client):
    """AGENTS.md, rule 8: the history comes from the versioned table, never from `revision`."""
    for path in ("/", "/?at=2010-01-01", f"/article/{CU}?at=2010-01-01", f"/article/{CU}/history",
                 f"/article/{CU}/diff?to=2010-01-01", f"/article/{CU}/phrase?q=Bremen",
                 "/search?q=Bremen", "/about", "/lab/", f"/lab/{LAB_NOTES}"):
        assert client.get(path).status_code == 200, path
        for entry in client.db.log:
            assert not re.search(r"\b(revision|page)\b", entry["sql"]), (path, entry["sql"])


# ---------------------------------------------------------------------------
# The lab: history made by the server
# ---------------------------------------------------------------------------

def test_lab_refuses_a_form_without_its_token(client):
    before = lab_versions(client)
    # A visitor who never opened the lab has no token: no token is not a match for that.
    assert client.post(f"/lab/{LAB_NOTES}/save", data={"content": "sneaky"}).status_code == 400
    assert client.post(f"/lab/{LAB_NOTES}/delete", data={"form_token": ""}).status_code == 400
    # A visitor with a token, and a form with a different one.
    form_token(client, f"/lab/{LAB_NOTES}")
    assert client.post(f"/lab/{LAB_NOTES}/delete", data={"form_token": "guessed"}).status_code == 400
    assert client.post(f"/lab/{LAB_NOTES}/save", data={"content": "sneaky"}).status_code == 400
    assert lab_versions(client) == before


def test_lab_edit_restore_delete_undelete(client):
    token = form_token(client, f"/lab/{LAB_NOTES}")
    original, versions = lab_text(client), lab_versions(client)

    # An edit is one UPDATE; the server adds the version.
    saved = client.post(f"/lab/{LAB_NOTES}/save",
                        data={"form_token": token, "content": "Changed by a test.", "editor": "pytest"})
    assert saved.status_code == 302
    # All the page sent was the UPDATE: nothing in it mentions history.
    assert [entry["sql"].split()[0] for entry in client.db.log] == ["UPDATE"]
    assert "SYSTEM_TIME" not in client.db.log[0]["sql"]
    assert lab_text(client) == "Changed by a test."
    assert lab_versions(client) == versions + 1

    # Restore the text as it stood before the edit (the page's last demo step was 12:06).
    client.post(f"/lab/{LAB_NOTES}/restore",
                data={"form_token": token, "moment": "2026-11-01T12:06:30", "editor": "pytest"})
    assert lab_text(client) == original
    assert lab_versions(client) == versions + 2            # restoring is an edit too

    # Delete: no row, same history.
    client.post(f"/lab/{LAB_NOTES}/delete", data={"form_token": token})
    assert lab_text(client) is None
    assert lab_versions(client) == versions + 2
    assert "This page has been deleted" in body_of(client.get(f"/lab/{LAB_NOTES}"))
    assert "Deleted, but not forgotten" in body_of(client.get("/lab/"))

    # Undelete: the newest version in the history becomes the current row again.
    client.post(f"/lab/{LAB_NOTES}/undelete", data={"form_token": token, "editor": "pytest"})
    assert lab_text(client) == original
    assert lab_versions(client) == versions + 3

    # Undeleting a page that exists is refused, not doubled.
    assert client.post(f"/lab/{LAB_NOTES}/undelete", data={"form_token": token}).status_code == 400


def test_lab_shows_what_visitors_write_as_text_not_as_html(client):
    token = form_token(client, f"/lab/{LAB_NOTES}")
    client.post(f"/lab/{LAB_NOTES}/save",
                data={"form_token": token, "content": "<script>alert(1)</script>",
                      "editor": "<b>mallory</b>", "summary": "<img src=x>"})
    body = body_of(client.get(f"/lab/{LAB_NOTES}"))
    assert "<script>alert(1)</script>" not in body and "&lt;script&gt;alert(1)&lt;/script&gt;" in body
    assert "<b>mallory</b>" not in body and "<img src=x>" not in body


def test_lab_page_in_the_past_and_while_deleted(client):
    vandalised = body_of(client.get(f"/lab/{LAB_NOTES}?at=2026-11-01T12:03:30"))
    assert "MARIADB IS A KIND OF SEAL" in vandalised and "Restore this text" in vandalised
    gone = body_of(client.get(f"/lab/{LAB_NOTES}?at=2026-11-01T12:05:30"))
    assert "There was no such page" in gone
