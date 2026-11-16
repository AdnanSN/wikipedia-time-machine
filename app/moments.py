"""Moments in time: reading them from a URL, writing them back, and saying them in words.

Everything in this project is UTC (see AGENTS.md, rule 7). A moment is a plain
`datetime` without a time zone that always means UTC, which is also what the database
connection returns for `row_start` and `row_end`.
"""

from datetime import datetime, timedelta

ONE_MICROSECOND = timedelta(microseconds=1)

# What a reader may type or a link may carry, most precise first.
_FORMATS = (
    "%Y-%m-%dT%H:%M:%S.%f",
    "%Y-%m-%dT%H:%M:%S",
    "%Y-%m-%dT%H:%M",
    "%Y-%m-%d %H:%M:%S.%f",
    "%Y-%m-%d %H:%M:%S",
    "%Y-%m-%d %H:%M",
    "%Y-%m-%d",
    "%Y",
)

# TIMESTAMP columns start in 1970, and nothing was saved on Wikipedia before 2001.
EARLIEST = datetime(1970, 1, 2)
LATEST = datetime(2100, 1, 1)


def parse_moment(text):
    """A moment from a URL parameter, or None if the text is empty or not a date."""
    if not text:
        return None
    text = text.strip().rstrip("Z")
    for pattern in _FORMATS:
        try:
            moment = datetime.strptime(text, pattern)
        except ValueError:
            continue
        return min(max(moment, EARLIEST), LATEST)
    return None


def for_url(moment):
    """`2010-06-01T00:00:00`, with microseconds only when they are not zero.

    Wikipedia saves to the second. The load spreads saves made in the same second one
    microsecond apart, so a link to such a version needs the microseconds to find it.
    """
    if moment.microsecond:
        return moment.strftime("%Y-%m-%dT%H:%M:%S.%f")
    return moment.strftime("%Y-%m-%dT%H:%M:%S")


def for_sql(moment):
    """`2010-06-01 00:00:00.000000`: the value for a TIMESTAMP literal or parameter."""
    return moment.strftime("%Y-%m-%d %H:%M:%S.%f")


def for_statement(moment):
    """The moment as the pages print it inside a statement: microseconds only if not zero."""
    if moment.microsecond:
        return moment.strftime("%Y-%m-%d %H:%M:%S.%f")
    return moment.strftime("%Y-%m-%d %H:%M:%S")


def for_input(moment):
    """The value of an `<input type="datetime-local" step="1">`."""
    return moment.strftime("%Y-%m-%dT%H:%M:%S")


def in_words(moment, seconds=False):
    """`1 June 2010, 00:00 UTC`. Seconds are shown when asked for or when not zero."""
    text = f"{moment.day} {moment.strftime('%B %Y')}, {moment.strftime('%H:%M')}"
    if seconds or moment.second or moment.microsecond:
        text += moment.strftime(":%S")
    return text + " UTC"


def day_in_words(moment):
    """`1 June 2010`."""
    return f"{moment.day} {moment.strftime('%B %Y')}"


def span_in_words(start, end):
    """How long something lasted, in the largest unit that fits: `11 seconds`, `3 years`."""
    seconds = max((end - start).total_seconds(), 0)
    for size, name in ((365.25 * 86400, "year"), (30.44 * 86400, "month"), (86400, "day"),
                       (3600, "hour"), (60, "minute")):
        if seconds >= size:
            count = seconds / size
            # One decimal for small counts ("1.5 years"), none for the rest.
            shown = f"{count:.1f}".rstrip("0").rstrip(".") if count < 10 else f"{count:.0f}"
            return f"{shown} {name}{'' if shown == '1' else 's'}"
    if seconds < 1:
        return "less than a second"
    whole = int(seconds)
    return f"{whole} second{'' if whole == 1 else 's'}"
