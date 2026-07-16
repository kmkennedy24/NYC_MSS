# Author: Katie Kennedy
# Purpose: Define theme details for dashboard
# Created: 07/2026
# Last Modified: 07/16/2026

library(bslib)


harbor_theme <- bs_theme(
  version = 5,

  base_font = font_google("Public Sans"),
  heading_font = font_google("Public Sans", wght = "700"),
  font_scale = 0.95,
  bg      = "#FFFFFF",
  fg      = "#1B1B1B",
  primary = "#0A5EA6",
  info    = "#2E6DA4")
