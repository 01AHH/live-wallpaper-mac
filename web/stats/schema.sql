-- Running totals per wallpaper (id = the catalog id).
CREATE TABLE IF NOT EXISTS stats (
  id        TEXT PRIMARY KEY,
  downloads INTEGER NOT NULL DEFAULT 0,
  votes     INTEGER NOT NULL DEFAULT 0
);
-- One vote per person per wallpaper. `voter` is a salted hash of the IP
-- address — the address itself is never stored.
CREATE TABLE IF NOT EXISTS votes (
  id    TEXT NOT NULL,
  voter TEXT NOT NULL,
  PRIMARY KEY (id, voter)
);
-- A person's downloads count once per wallpaper per day, so repeated clicks
-- can't inflate the totals.
CREATE TABLE IF NOT EXISTS downloads (
  id    TEXT NOT NULL,
  voter TEXT NOT NULL,
  day   TEXT NOT NULL,
  PRIMARY KEY (id, voter, day)
);
