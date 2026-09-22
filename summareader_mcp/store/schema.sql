-- The mirror's own schema, named the app's way.
--
-- A subset, not a copy: no retention columns, no push queue, no migrations.
-- What it does share is every table and column name it has, because
-- `--library` mode opens the app's own database with exactly this SQL. Two
-- files that disagree about what a column is called would mean two of every
-- query, and the second one is the one that goes wrong.
--
-- There is no schema version here on purpose. This file is a cache of a log
-- that can be replayed from zero, so a format change deletes it and pulls
-- again rather than migrating.

CREATE TABLE IF NOT EXISTS channels (
  id             TEXT PRIMARY KEY,
  kind           TEXT NOT NULL,
  url            TEXT NOT NULL,
  title          TEXT,
  -- Which group it is filed under; null is Ungrouped, which has no row in
  -- the app either. Deliberately not a foreign key: a source can name a
  -- group whose own record has not arrived yet, and it is ungrouped until
  -- it does rather than refused.
  group_id       TEXT
);

-- The groups sources are filed in. No row for Ungrouped: it is what a null
-- group_id means, and it exists on every device by definition.
--
-- The account a group names is *not* here. It is a label for a set of
-- sign-ins on the device that made it, and this mirror fetches nothing.
CREATE TABLE IF NOT EXISTS source_groups (
  id             TEXT PRIMARY KEY,
  kind           TEXT NOT NULL,
  title          TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS items (
  id             TEXT PRIMARY KEY,
  canonical_url  TEXT NOT NULL,
  fetch_url      TEXT,
  title          TEXT,
  author         TEXT,
  lang           TEXT,
  description    TEXT,
  discussion_url TEXT,
  published_at   INTEGER,
  fetched_at     INTEGER,
  duration_ms    INTEGER,
  read           INTEGER NOT NULL DEFAULT 0,
  -- When this mirror learned it was read. The log carries no read time, so
  -- this is arrival, not the moment somebody finished reading.
  read_at        INTEGER,
  text_blob      TEXT,
  image_blob     TEXT
);

CREATE TABLE IF NOT EXISTS item_channels (
  item_id        TEXT NOT NULL,
  channel_id     TEXT NOT NULL,
  first_seen_at  INTEGER,
  PRIMARY KEY (item_id, channel_id)
);

-- Newest wins when several models have had a go at the same item, which is
-- why created_at is here and why the reader orders by it.
CREATE TABLE IF NOT EXISTS summaries (
  item_id        TEXT NOT NULL,
  model_id       TEXT NOT NULL,
  created_at     INTEGER,
  text           TEXT,
  -- The app keeps queued, working and failed rows here too, and a failed one
  -- is not a summary. Read paths filter on this; the mirror only ever writes
  -- 'ok', because the log only carries finished ones.
  state          TEXT NOT NULL DEFAULT 'ok',
  PRIMARY KEY (item_id, model_id)
);

-- The column is `text`, not `body`. That is what the app calls it, and this
-- schema borrows its names so one query reads either file.
CREATE TABLE IF NOT EXISTS extracted_texts (
  item_id        TEXT PRIMARY KEY,
  text           TEXT NOT NULL,
  word_count     INTEGER
);

-- Tags, on an item and on a source. Two tables rather than one with an owner
-- column, so each keeps a real foreign key and a deletion takes its tags with
-- it. An item is searched by its source's tags as well as its own: tagging a
-- feed is how a hundred articles get organized at once.
CREATE TABLE IF NOT EXISTS item_tags (
  item_id        TEXT NOT NULL,
  tag            TEXT NOT NULL,
  PRIMARY KEY (item_id, tag)
);

CREATE TABLE IF NOT EXISTS channel_tags (
  channel_id     TEXT NOT NULL,
  tag            TEXT NOT NULL,
  PRIMARY KEY (channel_id, tag)
);

-- Where this mirror has read up to, and on which server. The seq is
-- transport-local, so a cursor without its instance is a number that means
-- nothing.
CREATE TABLE IF NOT EXISTS settings (
  key            TEXT PRIMARY KEY,
  value          TEXT
);

CREATE INDEX IF NOT EXISTS items_published ON items(published_at);
CREATE INDEX IF NOT EXISTS item_channels_channel ON item_channels(channel_id);
CREATE INDEX IF NOT EXISTS item_tags_tag ON item_tags(tag);
CREATE INDEX IF NOT EXISTS channel_tags_tag ON channel_tags(tag);
