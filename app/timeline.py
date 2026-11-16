"""The picture of an article's life: its size over time, drawn as one SVG shape.

Every version of an article has a start (`row_start`) and a size (`len`). Drawn as a
staircase from the first save to the newest, the history looks like layers of sediment:
long quiet stretches, growth spurts, and thin vertical cuts where the text was blanked
or vandalised and restored seconds later. The reader picks a moment on this picture.

Only arithmetic happens here; the template draws the result.
"""

from datetime import datetime

WIDTH = 1000    # the drawing's own coordinates; the page scales it to any width
HEIGHT = 120


def strata(points, start, end, moment=None):
    """Describe the drawing.

    points   [(when, size), ...] oldest first: one entry per version
    start    the left edge (the first save)
    end      the right edge (the newest save in the whole data set)
    moment   where the reader is, or None for "now"

    Returns {"path": the SVG outline, "years": [(x, label or None), ...],
             "needle": x of the reader's moment, "largest": the biggest size seen}.
    """
    span = max((end - start).total_seconds(), 1.0)
    largest = max((size or 0 for _, size in points), default=0) or 1

    def x_of(when):
        share = (when - start).total_seconds() / span
        return round(min(max(share, 0.0), 1.0) * WIDTH, 1)

    def y_of(size):
        return round(HEIGHT - (size or 0) / largest * (HEIGHT - 4), 1)

    path, last_x = [], None
    for when, size in points:
        x, y = x_of(when), y_of(size)
        if last_x is None:
            path.append(f"M{x},{HEIGHT}V{y}")       # the article is created
        elif x > last_x:
            path.append(f"H{x}V{y}")                # it stood, then it was edited
        else:
            path.append(f"V{y}")                    # several edits in the same pixel
        last_x = x
    if path:
        path.append(f"H{WIDTH}V{HEIGHT}Z")

    years_shown = end.year - start.year
    step = 1 if years_shown <= 12 else 2 if years_shown <= 26 else 5
    years = []
    for year in range(start.year + 1, end.year + 1):
        x = x_of(datetime(year, 1, 1))
        if 0 < x < WIDTH:
            years.append((x, str(year) if year % step == 0 else None))

    needle = WIDTH if moment is None else x_of(moment)
    # start_ms and end_ms let the page's script turn a click position back into a time.
    return {"path": "".join(path), "years": years, "needle": needle, "largest": largest,
            "start_ms": _epoch_ms(start), "end_ms": _epoch_ms(end)}


def year_bars(years):
    """Bars for the front page: edits per year, as shares of the busiest year.

    years  [{"year": 2002, "edits": 12}, ...]
    Returns [{"year", "edits", "height"}], height from 0 to 100.
    """
    busiest = max((row["edits"] for row in years), default=1) or 1
    return [{"year": row["year"], "edits": row["edits"],
             "height": max(round(row["edits"] / busiest * 100), 2)} for row in years]


def _epoch_ms(moment):
    """Milliseconds since 1970 for a UTC datetime without a time zone."""
    return int((moment - datetime(1970, 1, 1)).total_seconds() * 1000)
