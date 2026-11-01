#' Seasonal SWE for one SNOTEL station against its normals.
#'
#' plot_snodas() from mco-snodas (62fe19a) for a station: the same frame,
#' classes, keys, logos and labels, with SWE in inches. The shared helpers are
#' the normals package's plot_*() functions.
#'
#' @param x One station's rows for every date of the water year: date, swe and
#'   swe_ptile (observed dates), and quantile columns q0010 … q0990, in inches.
#' @param station One row of stations/stations.parquet.
#' @param normals_label Caption naming the normals, e.g. "Smoothed History".
#' @param ref_years First and last reference water years, for the legend title.
#' @param y_max Top of the SWE axis (inches), shared across flavors.
#' @return The plot, wrapped by normals::plot_legend_row().
plot_snotel <-
  function(x, station, normals_label = NULL, ref_years, y_max = NULL) {

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
      else normals::plot_conditions(the_record$swe, the_record$q0500, the_record$swe_ptile)

    b <- normals::plot_bands(usdm = TRUE)
    ribbons <-
      purrr::imap_dfr(b$bands, \(cols, nm) x %>%
                        dplyr::transmute(date, ribbon = nm,
                                         ymin = .data[[cols[1]]], ymax = .data[[cols[2]]])) %>%
      dplyr::mutate(ribbon = factor(ribbon, levels = rev(names(b$bands)), ordered = TRUE))

    lines <- x %>%
      # The outer edges; the median is drawn dashed below.
      dplyr::select(date, `1st percentile` = q0010, `99th percentile` = q0990) %>%
      tidyr::pivot_longer(-date)

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
      scale_x_date(breaks = normals::plot_month_breaks, labels = normals::plot_month_labels,
                   expand = expansion(0,0),
                   name = NULL) +

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
      normals::plot_current_legend(obs_lwd = 1) +

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
            plot.title = element_text(face = "bold", size = normals::PLOT_TITLE_SIZE,
                                      hjust = 0.0),
            plot.subtitle = element_text(face = "bold", hjust = 0.0),
            plot.caption = element_text(hjust = 0, color = "gray40"),
            plot.caption.position = "plot",
            axis.title = element_text(face = "bold")
      ) +
      normals::plot_legend_theme()) %>%
      ggplot2::ggplotGrob() %>%
      # No x title, and the month labels take two lines: the title row is cut
      # so the panel's bottom edge matches the hypsomeSWE plot's.
      normals::plot_fix_frame(xlab_height = grid::unit(5, "pt")) %>%
      normals::plot_legend_row()
  }
