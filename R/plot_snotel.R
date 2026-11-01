#' Seasonal SWE for one SNOTEL station against its normals.
#'
#' plot_snodas() from mco-snodas (62fe19a) for a station: the same frame,
#' classes, keys, logos and labels, with SWE in inches. The shared helpers are
#' vendored in R/plot.R.
#'
#' @param x One station's rows for every date of the water year: date, swe and
#'   swe_ptile (observed dates), and quantile columns q0010 … q0990, in inches.
#' @param station One row of stations/stations.parquet.
#' @param normals_label Caption naming the normals, e.g. "Smoothed History".
#' @param ref_years First and last reference water years, for the legend title.
#' @param y_max Top of the SWE axis (inches), shared across flavors.
#' @param outlook The outlook from the plotted date (date, q0100, q0900; see
#'   R/outlook.R), drawn as the likely range and keyed with the current
#'   conditions; NULL for none.
#' @return The plot, wrapped by snodas_legend_row().
plot_snotel <-
  function(x, station, normals_label = NULL, ref_years, y_max = NULL, outlook = NULL) {

    x <- dplyr::arrange(x, date)
    the_record <- x %>% dplyr::filter(!is.na(swe)) %>% dplyr::slice_tail(n = 1)
    the_date <- the_record$date

    # A station with too short a record has no normals; its SWE is drawn alone.
    no_normals <- all(is.na(x$q0500))
    # With no SWE this season or in the normals, draw a placeholder in the same
    # frame so every station has a plot to link to.
    snow_free <- !any(c(x$swe, x$q0990) > 0, na.rm = TRUE)

    conditions <-
      if (no_normals) "Too short a record for normals"
      else if (snow_free) "No snow on record"
      else snodas_conditions(the_record$swe, the_record$q0500, the_record$swe_ptile)

    b <- snodas_bands(usdm = TRUE)
    ribbons <-
      purrr::imap_dfr(b$bands, \(cols, nm) x %>%
                        dplyr::transmute(date, ribbon = nm,
                                         ymin = .data[[cols[1]]], ymax = .data[[cols[2]]])) %>%
      dplyr::mutate(ribbon = factor(ribbon, levels = rev(names(b$bands)), ordered = TRUE))

    lines <- x %>%
      # The outer edges; the median is drawn dashed below.
      dplyr::select(date, `1st percentile` = q0010, `99th percentile` = q0990) %>%
      tidyr::pivot_longer(-date)

    # The likely range starts at the plotted date's SWE, so it joins the line.
    ol <- if (!is.null(outlook) && nrow(outlook) && length(the_date))
      dplyr::bind_rows(tibble::tibble(date = the_date, q0100 = the_record$swe, q0900 = the_record$swe),
                       dplyr::select(outlook, date, q0100, q0900))

    title <- paste0("Seasonal SWE for ", station$name, " (", station$site_id, ", ", station$state, ")")
    caption <- paste0(c(normals_label,
                        paste0("SNOTEL ", station$triplet, ", ",
                               format(round(station$elevation_ft), big.mark = ","), " ft")),
                      collapse = " · ")
    (ggplot() +
      labs(
        title = title,
        subtitle = paste0(format(the_date, format = "%B %d, %Y"), " — ", conditions),
        caption = caption
      ) +

      ## HISTORICAL CONDITIONS
      # Thin white edges help adjacent classes read as separate bands.
      geom_ribbon(data = ribbons,
                  mapping = aes(x = date, ymin = ymin, ymax = ymax, fill = ribbon),
                  alpha = 0.7, colour = "white", linewidth = 0.15,
                  # Plain filled keys, the same glyph as the hypsomeSWE plot's.
                  key_glyph = "rect", na.rm = TRUE) +
      geom_line(data = lines, mapping = aes(x = date, y = value, color = name), na.rm = TRUE) +
      # The median dashed and gray, as on the hypsomeSWE plot.
      geom_line(data = x, mapping = aes(x = date, y = q0500, linetype = "Median"),
                colour = "gray50", na.rm = TRUE) +
      # USDM: drought classes on one row, pluvial on the other, extremes aligned.
      scale_fill_manual(name = paste0("Historical Conditions WY", ref_years[1], "–", ref_years[2]),
                        values = rev(b$colors),
                        limits = rev(b$legend),
                        breaks = c("D4", "D3", "D2", "D1", "D0", "W4", "W3", "W2", "W1", "W0"),
                        na.value = "#FFFFFF80",
                        guide = guide_legend(
                          order = 1,
                          nrow = 2,
                          byrow = TRUE,
                          title.position = "top",
                          override.aes = list(alpha = 0.7)
                        )) +
      scale_color_manual(name = NULL,
                         values = c(`99th percentile` = dplyr::last(b$colors),
                                    `1st percentile` = dplyr::first(b$colors)),
                         breaks = c("99th percentile", "1st percentile"),
                         guide = "none") +
      scale_y_continuous(limits = c(0, if (is.null(y_max)) NA else y_max),
                         expand = expansion(c(0,0.05),0),
                         breaks = if (snow_free) 0 else waiver(),
                         name = "Snow Water Equivalent (inches)") +
      scale_x_date(breaks = snodas_month_breaks, labels = snodas_month_labels,
                   expand = expansion(0,0),
                   name = NULL) +

      ## OUTLOOK
      # The likely range for the rest of the year (10th-90th percentile of the
      # outlook), with dotted edges so it reads over the classes.
      {if (!is.null(ol)) list(
        geom_ribbon(data = ol, mapping = aes(x = date, ymin = q0100, ymax = q0900, linetype = "Likely range"),
                    fill = "gray15", alpha = 0.22, colour = NA, key_glyph = "rect", na.rm = TRUE),
        geom_line(data = ol, mapping = aes(x = date, y = q0100), colour = "gray25",
                  linewidth = 0.3, linetype = "dotted", na.rm = TRUE),
        geom_line(data = ol, mapping = aes(x = date, y = q0900), colour = "gray25",
                  linewidth = 0.3, linetype = "dotted", na.rm = TRUE)
      )} +

      ## CURRENT CONDITIONS
      # White halo under the observed line, as on the hypsomeSWE plot.
      geom_line(data = x %>% dplyr::filter(!is.na(swe)),
                mapping = aes(x = date, y = swe),
                color = "white", linewidth = 1.8, lineend = "round") +
      geom_line(data = x %>% dplyr::filter(!is.na(swe)),
                mapping = aes(x = date, y = swe, linetype = "Observed"),
                color = "black", linewidth = 1,
                lineend = "round") +
      # This year's line and the median, keyed as on the hypsomeSWE plot.
      {if (is.null(ol)) snodas_current_legend(obs_lwd = 1) else snotel_outlook_legend(obs_lwd = 1)} +

      {if (snow_free && !no_normals)
        annotation_custom(grid::textGrob(
          "No snow on record at this station",
          gp = grid::gpar(fontfamily = "Helvetica", fontsize = 14, col = "gray40")
        ))} +

      theme_bw(base_family = "Helvetica") +
      theme(legend.margin = margin(),
            panel.grid.minor.x = element_blank(),   # monthly gridlines only
            legend.position = "bottom",
            plot.title.position = "plot",
            plot.title = element_text(face = "bold", size = SNODAS_TITLE_SIZE,
                                      hjust = 0.0),
            plot.subtitle = element_text(face = "bold", hjust = 0.0),
            plot.caption = element_text(hjust = 0, color = "gray40"),
            plot.caption.position = "plot",
            axis.title = element_text(face = "bold")
      ) +
      snodas_legend_theme()) %>%
      ggplot2::ggplotGrob() %>%
      # No x title, and the month labels take two lines: the title row is cut
      # so the panel's bottom edge matches the hypsomeSWE plot's.
      fix_plot_frame(xlab_height = grid::unit(5, "pt")) %>%
      snodas_legend_row()
  }

# snodas_current_legend() (R/plot.R) with the outlook's likely range as a third
# key: Observed and Median in one column, Likely range beside them, so the
# legend row keeps its two-row height.
snotel_outlook_legend <- function(obs_lwd)
  ggplot2::scale_linetype_manual(
    name = "Current Conditions",
    values = c(Observed = "solid", Median = "dashed", `Likely range` = "solid"),
    limits = c("Observed", "Median", "Likely range"),
    drop = FALSE,
    guide = ggplot2::guide_legend(order = 3, title.position = "top", nrow = 2, byrow = FALSE,
                                  keywidth = grid::unit(24, "pt"),
                                  override.aes = list(colour = c("black", "gray50", NA),
                                                      linewidth = c(obs_lwd, 0.5, 0),
                                                      fill = c(NA, NA, "gray15"),
                                                      alpha = c(1, 1, 0.22)))
  )
