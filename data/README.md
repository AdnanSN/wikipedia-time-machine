# The data set

**30 English Wikipedia articles with their complete revision history up to 2026-11-01 00:00:00 UTC:** 13,354 revisions, 161.8 MB of wikitext. Compressed with xz, the whole history is 1.5 MB, because each revision repeats most of the one before it.

| File | What it is |
|------|------------|
| [articles.txt](articles.txt) | The stated set: the 30 titles, grouped by theme |
| [pages.tsv](pages.tsv) | One line per article: page id, title, number of revisions, first and last save time, last revision id, total bytes of text |
| `revisions/<page_id>.jsonl.xz` | One JSON object per revision, oldest first |

Each revision record has the fields `rev_id`, `parent_id`, `timestamp` (UTC), `minor`, `user`, `comment` (the edit summary), `size`, `sha1`, `tags`, `deleted` and `content` (the wikitext). `deleted` follows MediaWiki's bits: 1 means Wikipedia hid the text, 2 the summary, 4 the user name. Hidden values are stored as `null`. None of the 13,354 revisions in this set has hidden text; one has a hidden edit summary.

## How it was chosen

The brief asks for "a few dozen" articles. We measured candidates' history first: the article on Wikipedia itself has 38,120 revisions and 3.3 GB of text, MediaWiki 229 MB, SQL 192 MB. We picked 30 articles on the project's own subjects (MariaDB and its storage engines, how databases handle time and history, transactions, relational basics) plus our university's article, keeping the load to a size any laptop handles in seconds. The longest histories in the set are ACID (1,531 revisions), LAMP (1,401), Database index (1,011), and MariaDB and Constructor University (1,007 each). The oldest revision is from 25 February 2002, the newest from 28 October 2026.

## How to get it again

The files are committed, so nothing has to be downloaded. To check them, without network access:

```bash
python scripts/fetch_revisions.py --check
```

To download them again from the MediaWiki API (about 300 requests and five minutes):

```bash
python scripts/fetch_revisions.py --force
```

Because only revisions saved before the cutoff are fetched, this gives the same data, unless Wikipedia's administrators have hidden or deleted old revisions since. The script verifies every revision's text against the SHA-1 Wikipedia reports for it, and stops if one does not match.

## Licence

The article text is from [English Wikipedia](https://en.wikipedia.org/) and is available under the [Creative Commons Attribution-ShareAlike 4.0 License](https://creativecommons.org/licenses/by-sa/4.0/). Its authors are the editors named in each revision's `user` field; the full history of each article is at `https://en.wikipedia.org/w/index.php?curid=<page_id>&action=history`.
