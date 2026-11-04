-- 01_schema.sql: the database and its three tables.
--
-- `page` and `revision` are how Wikipedia's own software, MediaWiki, keeps history:
-- application code writes a new revision row on every edit and points the page at it.
-- (Simplified: MediaWiki also splits the text into separate content and slot tables.)
--
-- `article` is the same history kept by MariaDB itself. It holds one row per article,
-- the current text, and WITH SYSTEM VERSIONING makes the server keep every earlier
-- version of that row, queryable with FOR SYSTEM_TIME. 02_build_history.sql fills it.
--
-- This script drops and recreates the wiki_time_machine database.

DROP DATABASE IF EXISTS wiki_time_machine;
CREATE DATABASE wiki_time_machine CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE wiki_time_machine;

-- The Wikipedia way, part 1: one row per article, pointing at its latest revision.
CREATE TABLE page (
  page_id     INT UNSIGNED NOT NULL PRIMARY KEY,  -- Wikipedia's page id; survives renames
  page_title  VARCHAR(255) NOT NULL UNIQUE,       -- title as of the cutoff date
  page_latest INT UNSIGNED NOT NULL               -- rev_id of the newest revision we loaded
);

-- The Wikipedia way, part 2: one row per edit, written by the application.
CREATE TABLE revision (
  rev_id         INT UNSIGNED NOT NULL PRIMARY KEY,
  rev_page       INT UNSIGNED NOT NULL,
  rev_parent_id  INT UNSIGNED NULL,               -- the revision this edit was made on top of
  rev_timestamp  DATETIME NOT NULL,               -- UTC, to the second, as MediaWiki stores it
  rev_minor_edit BOOLEAN NOT NULL,
  rev_actor      VARCHAR(255) NULL,               -- user name or IP address; NULL if hidden
  rev_comment    TEXT NULL,                       -- edit summary; NULL if hidden
  rev_len        INT UNSIGNED NULL,               -- text length in bytes
  rev_sha1       CHAR(40) NULL,                   -- SHA-1 of the text, as Wikipedia reports it
  rev_tags       VARCHAR(1024) NULL,              -- change tags, comma-separated
  rev_deleted    TINYINT UNSIGNED NOT NULL,       -- 1 = text hidden, 2 = summary, 4 = user
  content        MEDIUMTEXT NULL,                 -- the wikitext; NULL if hidden by Wikipedia
  KEY rev_page_timestamp (rev_page, rev_timestamp),
  CONSTRAINT revision_page FOREIGN KEY (rev_page) REFERENCES page (page_id)
);

-- The MariaDB way: one row per article, and the server keeps the history.
-- row_start and row_end are the system period: when this version of the row became
-- current and when it stopped being current. They are normally set by the server from
-- the clock; 02_build_history.sql sets them to the real Wikipedia save times instead
-- (see docs/decisions/0001-time-model.md for why, and for the alternatives).
CREATE TABLE article (
  page_id    INT UNSIGNED NOT NULL,
  title      VARCHAR(255) NOT NULL,
  rev_id     INT UNSIGNED NOT NULL,               -- the Wikipedia revision this version is
  editor     VARCHAR(255) NULL,
  summary    TEXT NULL,
  minor_edit BOOLEAN NOT NULL,
  len        INT UNSIGNED NULL,
  sha1       CHAR(40) NULL,
  tags       VARCHAR(1024) NULL,
  content    MEDIUMTEXT NULL,
  row_start  TIMESTAMP(6) GENERATED ALWAYS AS ROW START,
  row_end    TIMESTAMP(6) GENERATED ALWAYS AS ROW END,
  PERIOD FOR SYSTEM_TIME (row_start, row_end),
  PRIMARY KEY (page_id),          -- MariaDB adds row_end to it, so old versions can share page_id
  UNIQUE KEY title (title)
) WITH SYSTEM VERSIONING;
