# Author: Katie Kennedy
# Purpose:
# Created: 07/2026
# Last Modified: 07/16/2026
library(DBI)
library(RPostgres)
library(sf)
library(dplyr)

harbor <- readRDS("data/harbor_clean.rds")
# =============================================================================
# 1. CONNECT
# =============================================================================
con <- dbConnect(
  RPostgres::Postgres(),
  dbname   = "harbor",
  host     = "localhost",
  port     = 5432,
  user     = "postgres",
  password = Sys.getenv("PG_PASSWORD")   # never hard-code; read from .Renviron
)

# Smoke test: if this returns a version string, PostGIS is live in this database.
print(dbGetQuery(con, "SELECT PostGIS_Version();"))

# =============================================================================
# 2. CLASSIFY STATIONS
# =============================================================================
# This taxonomy came out of a foreign-key failure: 28 station codes appear in
# the measurements but have no coordinates. They are not random -- they fall
# into categories that mean different things and warrant different treatment.
#
#   qc_blank           -- laboratory control, NOT harbor water. Exclude from
#                         all water quality summaries (a category error otherwise).
#   special_study_2015 -- EJ1-EJ9, a discrete Jun-Nov 2015 study whose station
#                         registry was never published.
#   routine_unlocated  -- J13/J17: routine stations (43 samples each, same
#                         cadence as the rest of the J series) with no published
#                         coordinates. A genuine metadata gap.
#   substation         -- TR1-MA, N3C-85th St, etc. Sub-locations of a parent
#                         station, encoded in the station name.
#   routine            -- everything else.
classify_station <- function(x) {
  dplyr::case_when(
    x == "ERT Blk"         ~ "qc_blank",
    grepl("^EJ[0-9]+$", x) ~ "special_study_2015",
    x %in% c("J13", "J17") ~ "routine_unlocated",
    grepl("-", x)          ~ "substation",
    TRUE                   ~ "routine"
  )
}

# =============================================================================
# 3. BUILD THE STATIONS TABLE
# =============================================================================
# Normalization: coordinates belong to the STATION, not to every sample row.
# The source data repeats them per-record, which is exactly why heavily-sampled
# stations showed 20-59 km of coordinate scatter. One row per station fixes it.

# 3a. Located stations -- median of the valid records (median shrugs off strays).
stations_located <- harbor %>%
  filter(coord_status == "ok") %>%
  group_by(sampling_location) %>%
  summarise(
    lat          = median(lat_fixed,  na.rm = TRUE),
    long         = median(long_fixed, na.rm = TRUE),
    n_samples    = n(),
    first_sample = min(sample_date, na.rm = TRUE),
    last_sample  = max(sample_date, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(
    station_type = classify_station(sampling_location),
    has_location = TRUE
  ) %>%
  st_as_sf(coords = c("long", "lat"), crs = 4326, remove = FALSE)

# 3b. Unlocated stations -- KEEP them. The measurements are valid science; only
# the location metadata is missing. Dropping ~256 real samples because their
# coordinates are absent would be silent data loss.
orphans <- setdiff(unique(harbor$sampling_location),
                   stations_located$sampling_location)

stations_unlocated <- harbor %>%
  filter(sampling_location %in% orphans) %>%
  group_by(sampling_location) %>%
  summarise(
    n_samples    = n(),
    first_sample = min(sample_date, na.rm = TRUE),
    last_sample  = max(sample_date, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(
    lat          = NA_real_,
    long         = NA_real_,
    station_type = classify_station(sampling_location),
    has_location = FALSE,
    geometry     = st_sfc(rep(list(st_point()), dplyr::n()), crs = 4326)
  ) %>%
  st_as_sf()

stations_all <- bind_rows(stations_located, stations_unlocated)

# Audit summary -- this is the content for the dashboard's QA/QC tab.
stations_all %>%
  st_drop_geometry() %>%
  group_by(station_type, has_location) %>%
  summarise(stations = n(), records = sum(n_samples), .groups = "drop") %>%
  arrange(desc(records)) %>%
  print()

# =============================================================================
# 4. BUILD THE MEASUREMENTS TABLE
# =============================================================================
# No coordinates here -- location is reached by joining to `stations` on
# sampling_location. Store each fact once, in one place.
measurements <- harbor %>%
  st_drop_geometry() %>%
  select(-any_of(c("lat", "long", "lat_fixed", "long_fixed"))) %>%
  mutate(
    is_qc_sample = sampling_location %in%
      stations_all$sampling_location[stations_all$station_type == "qc_blank"]
  )

message(sprintf("Flagged %d QC records for exclusion from water quality summaries.",
                sum(measurements$is_qc_sample)))

# =============================================================================
# 5. WRITE TO POSTGIS
# =============================================================================
# Drop first so a partial previous run's constraints don't collide.
dbExecute(con, "DROP TABLE IF EXISTS measurements;")
dbExecute(con, "DROP TABLE IF EXISTS stations;")

st_write(stations_all, con, "stations", delete_layer = TRUE)  # creates geometry column
dbWriteTable(con, "measurements", measurements, overwrite = TRUE)

# =============================================================================
# 6. CONSTRAINTS + INDEX
# =============================================================================
# The foreign key makes the DATABASE refuse any measurement referencing a
# station that doesn't exist. This is QA/QC enforced at the storage layer --
# and it's the constraint that surfaced the 28 orphaned station codes.
dbExecute(con, "ALTER TABLE stations ADD PRIMARY KEY (sampling_location);")

dbExecute(con, "
  ALTER TABLE measurements
  ADD CONSTRAINT fk_station
  FOREIGN KEY (sampling_location) REFERENCES stations (sampling_location);
")

dbExecute(con, "CREATE INDEX stations_geom_idx ON stations USING GIST (geometry);")

message("Loaded successfully \u2014 foreign key constraint satisfied.")

# =============================================================================
# 7. VERIFY
# =============================================================================
# Reconciliation: total stations, total records, how many are actually mappable.
print(dbGetQuery(con, "
  SELECT station_type,
         COUNT(*) AS stations,
         SUM(n_samples) AS records,
         COUNT(*) FILTER (WHERE NOT ST_IsEmpty(geometry)) AS mapped
  FROM stations
  GROUP BY station_type
  ORDER BY records DESC;
"))

# =============================================================================
# 8. EXPORT FOR THE APP -- uses the SAME connection opened in Step 1
# =============================================================================
# (No second dbConnect here -- reuse `con`. Opening a duplicate orphans the
#  first connection and can hang.)

# Map + trends layer: located stations only, as sf.
stations_sf <- st_read(con, query =
                         "SELECT * FROM stations WHERE NOT ST_IsEmpty(geometry);")

# Measurements for analysis, QC blanks excluded.
measurements_out <- dbGetQuery(con,
                               "SELECT * FROM measurements WHERE NOT is_qc_sample;")

# Full station table (includes unlocated) for the QA/QC tab.
stations_all_out <- dbGetQuery(con, "SELECT * FROM stations;")

# Station-level audit summary for the QA/QC tab.
coord_audit <- dbGetQuery(con, "
  SELECT station_type, has_location,
         COUNT(*) AS stations, SUM(n_samples) AS records
  FROM stations GROUP BY station_type, has_location ORDER BY records DESC;
")

# Record-level flagged rows for the QA/QC tab. Built from `harbor` (the FULL
# frame), so it actually contains the missing/unresolved records.
harbor_flagged <- harbor %>%
  st_drop_geometry() %>%
  dplyr::filter(coord_status != "ok") %>%
  dplyr::select(sampling_location, sample_date,
                lat, long, lat_fixed, long_fixed, coord_status)

message(sprintf("Flagged records for QA/QC tab: %d", nrow(harbor_flagged)))

# --- Save everything the app reads -------------------------------------------
saveRDS(stations_sf,      "data/stations_sf.rds")
saveRDS(measurements_out, "data/measurements.rds")
saveRDS(stations_all_out, "data/stations_all.rds")
saveRDS(coord_audit,      "data/coord_audit.rds")
saveRDS(harbor_flagged,   "data/harbor_flagged.rds")

dbDisconnect(con)
message("Export complete \u2014 5 .rds files written to data/")
