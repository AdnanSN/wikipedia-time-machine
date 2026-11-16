// Picking a moment on the picture of an article's life.
//
// The server has drawn the picture (templates/_picture.html) and told us which times
// its left and right edges stand for. A click or a drag turns a position into a time;
// letting go loads the article as it stood then. Everything the picture can do, the
// date field and the "previous edit" / "next edit" links can do without JavaScript.

(function () {
  "use strict";

  var picture = document.querySelector(".strata");
  if (!picture) { return; }

  var start = Number(picture.dataset.start);     // milliseconds since 1970, UTC
  var end = Number(picture.dataset.end);
  var needle = picture.querySelector(".needle");
  var label = picture.querySelector(".needle-label");
  var months = ["January", "February", "March", "April", "May", "June", "July",
                "August", "September", "October", "November", "December"];
  var chosen = null;

  function two(n) { return (n < 10 ? "0" : "") + n; }

  // The time under a pointer position, kept between the two edges.
  function timeAt(event) {
    var box = picture.getBoundingClientRect();
    var share = Math.min(Math.max((event.clientX - box.left) / box.width, 0), 1);
    return { share: share, date: new Date(start + share * (end - start)) };
  }

  function show(point) {
    var d = point.date;
    needle.style.left = (point.share * 100) + "%";
    label.textContent = d.getUTCDate() + " " + months[d.getUTCMonth()] + " " + d.getUTCFullYear();
    chosen = d;
  }

  // 2010-06-01T00:00:00, in UTC: the format the page's ?at= parameter takes.
  function forUrl(d) {
    return d.getUTCFullYear() + "-" + two(d.getUTCMonth() + 1) + "-" + two(d.getUTCDate()) +
           "T" + two(d.getUTCHours()) + ":" + two(d.getUTCMinutes()) + ":" + two(d.getUTCSeconds());
  }

  function go() {
    if (chosen) {
      window.location.href = picture.dataset.go + "?at=" + encodeURIComponent(forUrl(chosen));
    }
  }

  picture.addEventListener("pointerdown", function (event) {
    picture.classList.add("dragging");
    picture.setPointerCapture(event.pointerId);
    show(timeAt(event));
  });
  picture.addEventListener("pointermove", function (event) {
    if (picture.classList.contains("dragging")) { show(timeAt(event)); }
  });
  picture.addEventListener("pointerup", function () {
    picture.classList.remove("dragging");
    go();
  });
  picture.addEventListener("pointercancel", function () {
    picture.classList.remove("dragging");
  });

  // With the keyboard: the arrow keys follow the "previous edit" and "next edit" links.
  picture.addEventListener("keydown", function (event) {
    var link = null;
    if (event.key === "ArrowLeft") { link = document.querySelector(".controls a[rel=prev]"); }
    if (event.key === "ArrowRight") { link = document.querySelector(".controls a[rel=next]"); }
    if (link) { event.preventDefault(); window.location.href = link.href; }
  });
}());
