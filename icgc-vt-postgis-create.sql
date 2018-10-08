-- EDIT this if you want tables to be created in a different schema
BEGIN TRANSACTION;

CREATE SCHEMA IF NOT EXISTS icgc_vt;
SET LOCAL search_path TO icgc_vt, public;
--
-- The following tables have to be filled in by the user
--
CREATE TABLE IF NOT EXISTS layers (
    name text PRIMARY KEY,
    geometry_type text, -- maybe a type?
    minz smallint,
    maxz smallint,
    sql text
);

CREATE TABLE IF NOT EXISTS tiles (
    z integer NOT NULL,
    x integer NOT NULL,
    y integer NOT NULL,
    edge boolean,
    status integer,
    geom geometry(Polygon,3857)
);
CREATE INDEX IF NOT EXISTS idx_tiles_geom ON tiles USING GIST(geom);
CREATE INDEX IF NOT EXISTS idx_tiles_zxy  ON tiles (z,x,y);


-- 
-- Functions not to be called directly (private).
-- 
CREATE OR REPLACE FUNCTION _append_bytea(acum bytea, cur bytea) 
    RETURNS bytea 
    IMMUTABLE 
AS $$
    SELECT COALESCE(acum, ''::bytea) || cur;
$$ 
LANGUAGE SQL;

DROP AGGREGATE _pbfcat(bytea);
CREATE AGGREGATE _pbfcat(bytea) (
    SFUNC = _append_bytea,
    STYPE = bytea
);

-- Function to generate just one layer
CREATE OR REPLACE FUNCTION _layer_pbf(layer text, z integer, x integer, y integer)
  RETURNS bytea AS
$func$
DECLARE
  query TEXT;
  replaced TEXT;
  full_sql TEXT;
  result bytea := NULL;
  start_t timestamp := clock_timestamp();
BEGIN
   -- pg_typeof returns regtype, quoted automatically
   SELECT lower(sql) FROM layers WHERE name = layer AND z BETWEEN minz AND maxz INTO query;
   IF FOUND THEN
       replaced := replace(
                      replace(query, '!bbox!', format('TileBBox(%s, %s, %s)', z, x, y)),
                      '!zoom!', z::text);
       full_sql := format(
        'SELECT ST_AsMVT(_q, ''%s'', 4096, ''vt_geom'') FROM ('
        'SELECT row_to_json(_sql.*)::jsonb - ''geom''::text attributes, ST_AsMVTGeom(_sql.geom, TileBBox(%s, %s, %s), 4096, 32, true) AS vt_geom '
        'FROM (%s) AS _sql) AS _q ', 
        layer, z, x, y, replaced);
       EXECUTE full_sql INTO result; 
       RAISE NOTICE 'z=% x=% y=% layer=% len=% t=%', z,x,y, layer, length(result), (clock_timestamp() - start_t); 
   END IF;
    return result;
END;
$func$ 
LANGUAGE plpgsql;

--
-- PUBLIC INTERFACE
--
-- Function to generate a full tile with all layers.
-- This is the main entry point for the function.
CREATE OR REPLACE FUNCTION tile_pbf(z integer, x integer, y integer)
    RETURNS bytea AS
$func$
    SELECT _pbfcat(_layer_pbf(name, z, x, y)) 
    FROM layers WHERE z BETWEEN minz AND maxz;
$func$
LANGUAGE SQL;

-- SELECT length(tile_pbf(7, 64, 47));

END;
