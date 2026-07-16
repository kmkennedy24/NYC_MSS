# queries_demo.R
# Example PostGIS spatial queries against the harbor database.
# NOT part of the pipeline -- these illustrate what the spatial database can do.
# Useful as an interview/portfolio artifact and a README reference.
#
# The key detail: unlocated stations (J17, EJ series, etc.) are stored with
# EMPTY point geometries. ST_X()/ST_Y()/ST_Distance() error on empty points, so
# each query first filters to located stations in a CTE (WITH ... AS), then does
# the coordinate math on that clean subset.

library(DBI)
library(RPostgres)

con <- dbConnect(
  RPostgres::Postgres(),
  dbname = "harbor", host = "localhost", port = 5432,
  user = "postgres", password = Sys.getenv("PG_PASSWORD")
)

# --- 1. Closest station pairs, distance in METERS ----------------------------
# ST_Distance on ::geography returns true meters (plain geometry would return
# degrees, which are meaningless as distance). The CTE drops empty geometries
# so ST_Distance only ever sees real points.
print(dbGetQuery(con, "
  WITH located AS (
    SELECT sampling_location, geometry
    FROM stations
    WHERE NOT ST_IsEmpty(geometry)
  )
  SELECT a.sampling_location AS station,
         b.sampling_location AS neighbor,
         ROUND(ST_Distance(a.geometry::geography, b.geometry::geography)) AS meters
  FROM located a
  JOIN located b ON a.sampling_location < b.sampling_location
  ORDER BY meters
  LIMIT 10;
"))

# --- 2. Mean salinity per station (cross-table join) -------------------------
# Joins measurements to station geometry, excludes QC blanks. The CTE guarantees
# ST_X/ST_Y only run on real points. Swap top_salinity_psu for any parameter.
print(dbGetQuery(con, "
  WITH located AS (
    SELECT sampling_location, station_type, geometry
    FROM stations
    WHERE NOT ST_IsEmpty(geometry)
  )
  SELECT s.sampling_location,
         s.station_type,
         ST_X(s.geometry) AS long,
         ST_Y(s.geometry) AS lat,
         COUNT(m.*) AS n,
         AVG(NULLIF(m.top_salinity_psu, '')::numeric) AS mean_salinity
  FROM located s
  JOIN measurements m USING (sampling_location)
  WHERE NOT m.is_qc_sample
  GROUP BY s.sampling_location, s.station_type, s.geometry
  ORDER BY mean_salinity DESC NULLS LAST
  LIMIT 10;
"))

dbDisconnect(con)
