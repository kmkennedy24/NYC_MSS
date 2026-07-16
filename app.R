# Author: Katie Kennedy
# Purpose: create interactive shiny app with dashboard and tabs (map, QA/QC, trends, and data)
# to view the spatial distribution of defined WQ data available, QA/QC required, and overall relationships
# in the data from https://data.cityofnewyork.us/Environment/Harbor-Water-Quality/5uug-f49n
# Created: 07/2026
# Last Modified: 07/16/2026

library(shiny)
library(dplyr)
library(leaflet)
library(sf)

#### pre cleaned rds files or app ####
harbor_sf <- readRDS("data/harbor_sf.rds") %>%
  dplyr::left_join(
    sf::st_drop_geometry(readRDS("data/stations_sf.rds")) %>%
      dplyr::select(sampling_location, station_type),
    by = "sampling_location"
  )
stations_sf    <- readRDS("data/stations_sf.rds")
measurements   <- readRDS("data/measurements.rds")
stations_all   <- readRDS("data/stations_all.rds")
coord_audit    <- readRDS("data/coord_audit.rds")
harbor_flagged <- readRDS("data/harbor_flagged.rds")

stations <- sort(unique(harbor_sf$sampling_location))

standards <- list(
  ctd_conductivity_temperature_depth_profiler_top_dissolved_oxygen_mg_l = list(
    label = "DO < 4.8 mg/L (NYS SB/SC chronic)",
    fail  = function(v) v < 4.8
  ),
  top_enterococci_bacteria_cells_100ml = list(
    label = "Enterococci > 104 /100mL (EPA single-sample)",
    fail  = function(v) v > 104
  ),
  top_fecal_coliform_bacteria_cells_100ml = list(
    label = "Fecal coliform > 2000 /100mL (NYS SB)",
    fail  = function(v) v > 2000
  )
)

source("scripts/theme.R")

params <- c(
  "Dissolved oxygen (mg/L)"      = "ctd_conductivity_temperature_depth_profiler_top_dissolved_oxygen_mg_l",
  "Salinity (PSU)"               = "top_salinity_psu",
  "Water temperature (C)"        = "top_sample_temperature_c",
  "Enterococci (cells/100mL)"    = "top_enterococci_bacteria_cells_100ml"
)

#### UI: the layout ####
ui <- fluidPage(
  titlePanel("NYC Harbor Water Quality"),
  theme = harbor_theme,
  sidebarLayout(
    sidebarPanel(
      selectInput("param", "Parameter", choices = params),
      selectInput("station", "Station", choices = c("All stations", stations)),
      sliderInput("years", "Year range",
                  min = 2010, max = 2025, value = c(2010, 2025), sep = ""),
      checkboxInput("failing_only", "Show only samples failing the standard", FALSE)
    ),
    mainPanel(
      tabsetPanel(
        tabPanel("Map",
                 leafletOutput("map", height = 480),
                 uiOutput("map_caption")),
        tabPanel("Trends", plotOutput("trend", height = 420)),
        tabPanel("QA/QC",
                 tableOutput("qaqc"),
                 tableOutput("qaqc_detail")),
        tabPanel("Data",   tableOutput("table"))
      )
    )
  )
)

# map logic
server <- function(input, output, session) {

  filtered <- reactive({
    d <- harbor_sf

    if (input$station != "All stations") {
      d <- dplyr::filter(d, sampling_location == input$station)
    }

    yr <- lubridate::year(d$sample_date)
    d <- d[yr >= input$years[1] & yr <= input$years[2], ]

    d$value <- as.numeric(d[[input$param]])

    std <- standards[[input$param]]
    if (!is.null(std)) {
      d$fails <- std$fail(d$value)
      if (isTRUE(input$failing_only)) {
        d <- d[!is.na(d$fails) & d$fails, ]
      }
    } else {
      d$fails <- NA
    }
    d
  })

  output$map <- renderLeaflet({
    d <- filtered()
    std <- standards[[input$param]]

    m <- leaflet::leaflet(d) |>
      leaflet::addProviderTiles("CartoDB.Positron")

    if (!is.null(std)) {
      pal <- leaflet::colorFactor(c("#2E7D32", "#C62828"), domain = c(FALSE, TRUE),
                                  na.color = "#cccccc")
      m <- m |>
        leaflet::addCircleMarkers(
          radius = 5, stroke = FALSE, fillOpacity = 0.8,
          color = ~pal(fails),
          label = ~paste0(sampling_location, ": ", round(value, 1),
                          ifelse(is.na(fails), "",
                                 ifelse(fails, " (fails)", " (meets)")))
        ) |>
        leaflet::addLegend("bottomright", pal = pal, values = c(FALSE, TRUE),
                           labels = c("Meets standard", "Fails standard"),
                           title = std$label, opacity = 0.8)
    } else {
      vals <- d$value
      if (any(!is.na(vals))) {
        pal <- leaflet::colorNumeric("viridis", vals, na.color = "#cccccc")
        m <- m |>
          leaflet::addCircleMarkers(
            radius = 5, color = ~pal(vals), stroke = FALSE, fillOpacity = 0.8,
            label = ~paste0(sampling_location, ": ", round(vals, 1))
          ) |>
          leaflet::addLegend("bottomright", pal = pal, values = vals,
                             title = names(params)[params == input$param], opacity = 0.8)
      }
    }
    m
  })

  output$map_caption <- renderUI({
    std <- standards[[input$param]]
    if (!is.null(std)) {
      tags$p(
        style = "font-size:12px; color:#666; margin-top:6px;",
        sprintf("Individual samples flagged against %s. Screening view per NYS 6 NYCRR 703.3 and NYC DEP Harbor Survey categories; not a regulatory determination.",
                std$label)
      )
    } else {
      tags$p(
        style = "font-size:12px; color:#666; margin-top:6px;",
        paste0("Measured values for ", names(params)[params == input$param],
               ". No numeric standard applies; colored by value.")
      )
    }
  })

  output$trend <- renderPlot({
    d <- sf::st_drop_geometry(filtered())
    d$value <- as.numeric(d[[input$param]])
    d <- d[!is.na(d$value), ]
    plot(d$sample_date, d$value, type = "p", pch = 20,
         xlab = "Date", ylab = names(params)[params == input$param],
         main = "Selected parameter over time")
  })

  output$qaqc <- renderTable({
    harbor_flagged %>%
      dplyr::count(coord_status, name = "records")
  })

  output$qaqc_detail <- renderTable({
    harbor_flagged %>%
      dplyr::arrange(coord_status, sampling_location) %>%
      head(50)
  })

  output$table <- renderTable({
    sf::st_drop_geometry(filtered()) |>
      dplyr::select(sampling_location, sample_date, dplyr::all_of(input$param)) |>
      head(50)
  })
}

#final app
shinyApp(ui = ui, server = server)
