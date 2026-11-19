-- GET /v1/nearby searches growing distance windows (src/lib/nearby.ts). Each window reads only the users whose
-- home or travel cell is inside a latitude/longitude box: `locations_cell_idx` (001) covers home cells, this covers
-- travel cells. No extension needed (plain btree).
CREATE INDEX IF NOT EXISTS travel_locations_cell_idx ON travel_locations (cell_lat, cell_lon);

-- hideDistance users are listed only within the 3×3 block of 1° regions around the viewer, in pseudo-random order,
-- so every request has to look at all of them in that block. Without help that means looking up every user who
-- lives in the block (a whole metro area) to find the few hidden ones. A copy of users.hide_distance on the cell
-- rows, with partial indexes, finds just them. It's only a prefilter: queries still check users.hide_distance.
-- Kept in sync by the triggers below. Even if a copy were ever wrong it could only drop a hideDistance user from
-- lists, never show anyone more (and the next location update re-reads it).
ALTER TABLE locations ADD COLUMN IF NOT EXISTS hide_distance boolean NOT NULL DEFAULT false;
ALTER TABLE travel_locations ADD COLUMN IF NOT EXISTS hide_distance boolean NOT NULL DEFAULT false;
UPDATE locations l SET hide_distance = u.hide_distance
  FROM users u WHERE u.id = l.user_id AND l.hide_distance IS DISTINCT FROM u.hide_distance;
UPDATE travel_locations t SET hide_distance = u.hide_distance
  FROM users u WHERE u.id = t.user_id AND t.hide_distance IS DISTINCT FROM u.hide_distance;
CREATE INDEX IF NOT EXISTS locations_hidden_cell_idx ON locations (cell_lat, cell_lon) WHERE hide_distance;
CREATE INDEX IF NOT EXISTS travel_locations_hidden_cell_idx ON travel_locations (cell_lat, cell_lon) WHERE hide_distance;

-- Every write of a cell row copies the owner's current flag (whatever the writer put there).
CREATE OR REPLACE FUNCTION stexx_cell_copy_hide_distance() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- A new row (also the first step of an upsert): FOR SHARE waits for an in-flight change of the owner's flag to
    -- commit and then reads it. Without it, a flag change racing a user's first location could be missed: the
    -- users trigger below only rewrites rows that already exist.
    SELECT u.hide_distance INTO NEW.hide_distance FROM users u WHERE u.id = NEW.user_id FOR SHARE;
  ELSE
    -- An existing row is already locked by this statement and the users trigger may be waiting for it, so no lock
    -- here (it would deadlock). That trigger rewrites this row after we commit anyway.
    SELECT u.hide_distance INTO NEW.hide_distance FROM users u WHERE u.id = NEW.user_id;
  END IF;
  NEW.hide_distance := coalesce(NEW.hide_distance, false);
  RETURN NEW;
END $$;
CREATE OR REPLACE TRIGGER locations_copy_hide_distance BEFORE INSERT OR UPDATE ON locations
  FOR EACH ROW EXECUTE FUNCTION stexx_cell_copy_hide_distance();
CREATE OR REPLACE TRIGGER travel_locations_copy_hide_distance BEFORE INSERT OR UPDATE ON travel_locations
  FOR EACH ROW EXECUTE FUNCTION stexx_cell_copy_hide_distance();

-- And every change of the flag rewrites the copies (the BEFORE trigger above re-reads the new value).
CREATE OR REPLACE FUNCTION stexx_user_sync_hide_distance() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  UPDATE locations SET hide_distance = NEW.hide_distance WHERE user_id = NEW.id;
  UPDATE travel_locations SET hide_distance = NEW.hide_distance WHERE user_id = NEW.id;
  RETURN NULL;
END $$;
CREATE OR REPLACE TRIGGER users_sync_hide_distance AFTER UPDATE OF hide_distance ON users
  FOR EACH ROW WHEN (OLD.hide_distance IS DISTINCT FROM NEW.hide_distance)
  EXECUTE FUNCTION stexx_user_sync_hide_distance();

-- The distance functions from 001, made inlinable. They were STRICT with a non-strict body (least / CASE), and
-- Postgres never inlines such a function, so every row paid an SQL-function call (~1-3 µs each, most of the old
-- nearby query's time). Without STRICT the planner substitutes the expression. Same results for every input: the
-- bodies propagate NULL themselves (a CASE instead of least(), which would turn a NULL into 1.0), and
-- test/foundation.test.ts keeps them in parity with src/lib/distance.ts.
CREATE OR REPLACE FUNCTION stexx_haversine_m(lat1 double precision, lon1 double precision,
                                             lat2 double precision, lon2 double precision)
RETURNS double precision LANGUAGE sql IMMUTABLE CALLED ON NULL INPUT PARALLEL SAFE AS $$
  SELECT 2 * 6371000.0 * asin(CASE
    WHEN sqrt(power(sin(radians(lat2 - lat1) / 2), 2) +
              cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lon2 - lon1) / 2), 2)) > 1.0 THEN 1.0
    ELSE sqrt(power(sin(radians(lat2 - lat1) / 2), 2) +
              cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lon2 - lon1) / 2), 2))
  END)
$$;

-- Ties round half up, like JS Math.round (PG round(float) is half-even). A NULL distance falls through to the
-- last branch and stays NULL. Inlined when its argument is a plain column (nearby computes the raw distance in a
-- subquery for that reason); with an expression argument Postgres still calls it, as before.
CREATE OR REPLACE FUNCTION stexx_distance_bucket(m double precision) RETURNS integer
LANGUAGE sql IMMUTABLE CALLED ON NULL INPUT PARALLEL SAFE AS $$
  SELECT CASE
    WHEN m < 1000   THEN greatest(100, (ceil(m / 100.0) * 100)::integer)
    WHEN m < 5000   THEN (floor(m / 500.0 + 0.5) * 500)::integer
    WHEN m < 25000  THEN (floor(m / 1000.0 + 0.5) * 1000)::integer
    WHEN m < 100000 THEN (floor(m / 5000.0 + 0.5) * 5000)::integer
    ELSE (floor(m / 10000.0 + 0.5) * 10000)::integer
  END
$$;

-- Planner statistics for the tables the nearby search joins. Columns added by later migrations (users.hidden_at and
-- users.banned_at, 107) have none until auto-analyze happens to run, and without them Postgres guesses that
-- `hidden_at IS NULL AND banned_at IS NULL` matches almost nobody. On the shared test database that turned the old
-- nearby query into nested loops over the whole users table (seconds per request). Cheap; safe to repeat.
ANALYZE users;
ANALYZE locations;
ANALYZE travel_locations;
ANALYZE blocks;
ANALYZE favorites;
