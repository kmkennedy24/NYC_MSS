# Author: Katie Kennedy
# Purpose:Pull the NYC DEP Harbor Survey data (NYC Open Data asset 5uug-f49n) via the
# Socrata SoQL API, verify nothing was truncated, fix swapped coordinates, and
# save a cleaned frame for the PostGIS load step. Data is filtered to 2010-01-01 through 2025-12-31.
# Created: 07/2026
# Last Modified: 07/16/2026

library(httr2)
library(dplyr)
library(sf)

# ---- Parameters -------------------------------------------------------------
base_url   <- "https://data.cityofnewyork.us/resource/5uug-f49n.json"
date_start <- "2010-01-01T00:00:00"
date_end   <- "2025-12-31T23:45:00"  #adjust if desired

# ---- count records ---------------------------------------------------------
count_soql <- sprintf(
  "SELECT count(*) AS n
   WHERE sample_date
     BETWEEN '%s' :: floating_timestamp
     AND     '%s' :: floating_timestamp",
  date_start, date_end
)

app_token <- Sys.getenv("SODA_APP_TOKEN", unset = "")

add_token <- function(req) {
  if (nzchar(app_token)) req_headers(req, `X-App-Token` = app_token) else req
}


count_resp <- request(base_url) |>
  req_url_query(`$query` = count_soql) |>
  add_token() |>
  req_perform() |>
  resp_body_json(simplifyVector = TRUE)

n_expected <- as.integer(count_resp$n)
message(sprintf("API reports %d matching records.", n_expected))

# ---- pull rows based on guidance from platform (i.e. 1000 rows at a time) -------------------------------------

row_limit <- n_expected + 1000L

data_soql <- sprintf(
  "SELECT *
   WHERE sample_date
     BETWEEN '%s' :: floating_timestamp
     AND     '%s' :: floating_timestamp
   ORDER BY sample_date
   LIMIT %d",
  date_start, date_end, row_limit
)

raw <- request(base_url) |>
  req_url_query(`$query` = data_soql) |>
  add_token() |>
  req_perform() |>
  resp_body_json(simplifyVector = TRUE)

message(sprintf("Downloaded %d rows.", nrow(raw)))

# ---- match row count for all datasets ----------------------------------------
if (nrow(raw) < n_expected) {
  stop(sprintf(
    "Row count mismatch: expected %d, got %d. The pull was truncated \u2014 raise row_limit or paginate.",
    n_expected, nrow(raw)
  ))
}
message("Row count check passed \u2014 download is complete.")

# ---- coerce col types -------------------------------------------------------

harbor <- raw |>
  mutate(
    sample_date = as.Date(sample_date),
    across(c(lat, long), as.numeric)
  )

# ---- fix incorrectly inputted coordinates ---------------------------------------------

harbor <- harbor %>%
  dplyr::mutate(
    lat_fixed  = dplyr::case_when(lat < 0 ~ long, lat > 0 ~ lat, TRUE ~ NA_real_),
    long_fixed = dplyr::case_when(long > 39 ~ lat, long < 39 ~ long, TRUE ~ NA_real_),
    coord_status = dplyr::case_when(
      is.na(lat_fixed) | is.na(long_fixed) ~ "missing",
      lat_fixed  >= 40.40 & lat_fixed  <= 41.05 &
        long_fixed >= -74.30 & long_fixed <= -73.68 ~ "ok",
      TRUE ~ "unresolved"
    )
  )

# QA/QC records for the tab
message("Coordinate status summary:")
harbor %>% dplyr::count(coord_status) %>% print()

# ---- mapped stations into sf object ---------------------------
harbor_sf <- harbor %>%
  dplyr::filter(coord_status == "ok") %>%
  sf::st_as_sf(coords = c("long_fixed", "lat_fixed"), crs = 4326, remove = FALSE)

message(sprintf(
  "Built sf object: %d points across %d distinct stations.",
  nrow(harbor_sf),
  dplyr::n_distinct(harbor_sf$sampling_location)
))

# ---- save files for db ----------------------------------------------
saveRDS(harbor,    "data/harbor_clean.rds")
saveRDS(harbor_sf, "data/harbor_sf.rds")
message("Saved data/harbor_clean.rds and data/harbor_sf.rds")
