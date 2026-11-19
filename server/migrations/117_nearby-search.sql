-- GET /v1/nearby searches growing distance windows (src/lib/nearby.ts). Each window reads only the users whose
-- home or travel cell is inside a latitude/longitude box: `locations_cell_idx` (001) covers home cells, this covers
-- travel cells. No extension needed (plain btree).
CREATE INDEX IF NOT EXISTS travel_locations_cell_idx ON travel_locations (cell_lat, cell_lon);

-- Planner statistics for the tables the nearby search joins. Columns added by later migrations (users.hidden_at and
-- users.banned_at, 107) have none until auto-analyze happens to run, and without them Postgres guesses that
-- `hidden_at IS NULL AND banned_at IS NULL` matches almost nobody. On the shared test database that turned the old
-- nearby query into nested loops over the whole users table (seconds per request). Cheap; safe to repeat.
ANALYZE users;
ANALYZE locations;
ANALYZE travel_locations;
ANALYZE blocks;
ANALYZE favorites;
