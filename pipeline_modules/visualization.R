# Visualization module for methylation array analysis pipeline

#' Generate comprehensive report
#'
#' @param qc_results QC results
#' @param dim_reduction Dimensionality reduction results
#' @param cnv_data CNV analysis results
#' @param sample_info Sample information data frame
#' @param output_dirs Named list of module output directories (from setup_directories())
#' @param output_dir Output directory for reports
#' @return List of generated report paths
generate_report <- function(qc_results = NULL,
                          dim_reduction = NULL,
                          cnv_data = NULL,
                          sample_info = NULL,
                          output_dirs = NULL,
                          output_dir = ".") {

  report_files <- list()

  # ------------------------------------------------------------------
  # Check prerequisites for HTML rendering
  # ------------------------------------------------------------------
  has_rmarkdown <- requireNamespace("rmarkdown", quietly = TRUE)
  has_pandoc    <- has_rmarkdown && nchar(rmarkdown::find_pandoc()$dir) > 0
  has_DT        <- requireNamespace("DT", quietly = TRUE)
  has_knitr     <- requireNamespace("knitr", quietly = TRUE)

  render_html <- has_rmarkdown && has_pandoc && has_DT && has_knitr

  if (!has_rmarkdown) message("Package 'rmarkdown' not available \u2014 skipping HTML report.")
  if (has_rmarkdown && !has_pandoc) message("pandoc not found \u2014 skipping HTML report. ",
    "On HPC, try: module load pandoc  or set RSTUDIO_PANDOC.")
  if (!has_DT)    message("Package 'DT' not available \u2014 skipping HTML report.")
  if (!has_knitr) message("Package 'knitr' not available \u2014 skipping HTML report.")

  if (render_html) {
    message("Generating HTML report...")

    dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)
    abs_output_dir <- normalizePath(output_dir, winslash = "/", mustWork = TRUE)

    report_data <- list(
      qc_results      = qc_results,
      dim_reduction   = dim_reduction,
      cnv_data        = cnv_data,
      sample_info     = sample_info,
      output_dirs     = output_dirs,
      generation_time = Sys.time()
    )
    save(report_data, file = file.path(abs_output_dir, "report_data.RData"))

    rmd_file  <- create_report_rmd(abs_output_dir)
    html_file <- file.path(abs_output_dir, "methylation_analysis_report.html")

    render_ok <- tryCatch({
      rmarkdown::render(
        input       = rmd_file,
        output_file = basename(html_file),
        output_dir  = abs_output_dir,
        intermediates_dir = abs_output_dir,
        knit_root_dir     = abs_output_dir,
        quiet       = FALSE,
        envir       = new.env()
      )
      TRUE
    }, error = function(e) {
      message("HTML rendering failed: ", conditionMessage(e))
      message("  Rmd file kept at: ", rmd_file)
      message("  Falling back to plain-text report.")
      FALSE
    })

    if (render_ok) {
      message("HTML report saved: ", html_file)
      report_files$html <- html_file
    }
  }

  if (is.null(report_files$html)) {
    text_report <- generate_text_report(qc_results, dim_reduction, cnv_data, sample_info)
    text_file   <- file.path(output_dir, "methylation_analysis_report.txt")
    writeLines(text_report, text_file)
    message("Plain-text report saved: ", text_file)
    report_files$text <- text_file
  }

  return(report_files)
}

#' Create R Markdown report template
#'
#' @param output_dir Output directory
#' @return Path to created Rmd file
create_report_rmd <- function(output_dir) {
  yaml_header <- paste0('---
title: "MeQTrack Analysis Report"
author: "Methylation Pipeline"
date: "', format(Sys.time(), "%d %B, %Y"), '"
output:
  html_document:
    toc: true
    toc_float: true
    theme: cosmo
    highlight: tango
    self_contained: true
---')

  rmd_body <- '
```{r setup, include=FALSE}
knitr::opts_chunk$set(echo = FALSE, warning = FALSE, message = FALSE,
                      results = "asis")
library(DT)
library(knitr)

load("report_data.RData")

# Resolve a stored plot path to one that actually exists on disk.
# Prefers PNG over PDF at every candidate location.
resolve_plot_path <- function(stored_path, module_dir = NULL) {
  if (is.null(stored_path) || is.na(stored_path) || !nzchar(stored_path)) return(NULL)
  if (file.exists(stored_path)) return(stored_path)
  if (grepl("[.]pdf$", stored_path, ignore.case = TRUE)) {
    png_alt <- sub("[.]pdf$", ".png", stored_path)
    if (file.exists(png_alt)) return(png_alt)
  }
  fname     <- basename(stored_path)
  fname_png <- sub("[.]pdf$", ".png", fname, ignore.case = TRUE)
  if (!is.null(module_dir) && nzchar(module_dir)) {
    for (fn in unique(c(fname_png, fname))) {
      candidate <- file.path(module_dir, fn)
      if (file.exists(candidate)) return(candidate)
      candidate2 <- file.path(module_dir, "plots", fn)
      if (file.exists(candidate2)) return(candidate2)
    }
  }
  dirs <- c(file.path("..", "figures", "qc"),
            file.path("..", "figures", "cnv"),
            file.path("..", "qc", "plots"), file.path("..", "qc"),
            file.path("..", "cnv"), file.path("..", "cnv", "plots"), ".")
  for (d in dirs) {
    for (fn in unique(c(fname_png, fname))) {
      rel <- file.path(d, fn)
      if (file.exists(rel)) return(rel)
    }
  }
  return(NULL)
}

# Emit a base64-encoded <img> tag via cat() (works with results="asis").
embed_img <- function(path) {
  if (is.null(path) || !file.exists(path)) {
    cat("*Plot not available*\\n\\n"); return(invisible(NULL))
  }
  uri <- knitr::image_uri(path)
  cat(sprintf("<img src=\\"%s\\" alt=\\"%s\\" style=\\"width:100%%;max-width:1100px;height:auto;display:block;margin:1.25em auto;\\" />\\n\\n",
              uri, basename(path)))
  invisible(path)
}

show_table <- function(df, caption = "", ...) {
  if (!is.null(df) && is.data.frame(df) && nrow(df) > 0) {
    w <- DT::datatable(df, caption = caption,
                       options = list(pageLength = 10, scrollX = TRUE), ...)
    cat(knitr::knit_print(w))
  } else {
    cat("*Table not available*\\n\\n")
  }
}

odirs <- report_data$output_dirs
```

```{r report_css}
cat("<style>
.main-container img { display:block; width:100%!important; max-width:1100px; margin:1.25em auto; height:auto; }
</style>\\n")
```

# Overview

This report summarises the results of methylation array analysis performed using MeQTrack.

## Sample Information

```{r sample_info}
show_table(report_data$sample_info, caption = "Sample Information")
```

# Quality Control {.tabset}

```{r qc_check}
qc <- report_data$qc_results
has_qc <- !is.null(qc)
```

```{r qc_summary, eval=has_qc}
n_pass <- length(qc$passed_samples)
n_fail <- length(qc$failed_samples)
cat(sprintf("**%d samples passed QC** | **%d samples failed QC**\\n\\n", n_pass, n_fail))
```

## QC Metrics Table

```{r qc_table, eval=has_qc}
show_table(qc$sample_qc, caption = "Per-sample QC Metrics")
```

```{r qc_unavailable, eval=!has_qc}
cat("No QC results available.")
```

## Mean Detection P-value

```{r qc_detp, eval=has_qc}
p <- resolve_plot_path(qc$plots$mean_detection_pvalue,
                       if (!is.null(odirs)) odirs$figures_qc else NULL)
embed_img(p)
```

## Beta Density

```{r qc_density, eval=has_qc}
p <- resolve_plot_path(qc$plots$beta_density,
                       if (!is.null(odirs)) odirs$figures_qc else NULL)
embed_img(p)
```

## Beta Bean Plot

```{r qc_bean, eval=has_qc}
p <- resolve_plot_path(qc$plots$beta_bean,
                       if (!is.null(odirs)) odirs$figures_qc else NULL)
embed_img(p)
```

## MDS Plot

```{r qc_mds, eval=has_qc}
p <- resolve_plot_path(qc$plots$mds,
                       if (!is.null(odirs)) odirs$figures_qc else NULL)
embed_img(p)
```

## Interactive Plots

```{r qc_interactive, eval=has_qc}
idens <- resolve_plot_path(qc$plots$interactive_density,
                           if (!is.null(odirs)) odirs$figures_qc else NULL)
imds  <- resolve_plot_path(qc$plots$interactive_mds,
                           if (!is.null(odirs)) odirs$figures_qc else NULL)
if (!is.null(idens)) cat(sprintf("[Interactive density plot](%s)\\n\\n", basename(idens)))
if (!is.null(imds))  cat(sprintf("[Interactive MDS plot](%s)\\n\\n",     basename(imds)))
if (is.null(idens) && is.null(imds)) cat("*Interactive plots not available*\\n\\n")
```

# Copy Number Variation Analysis {.tabset}

```{r cnv_check}
cnv_data <- report_data$cnv_data
has_cnv  <- !is.null(cnv_data)
cnv_dir  <- if (!is.null(odirs)) odirs$figures_cnv else NULL
```

## CNV Segments

```{r cnv_segments, eval=has_cnv}
cat(sprintf("CNV analysis method: **%s**\\n\\n",
            if (!is.null(cnv_data$method)) cnv_data$method else "unknown"))
show_table(cnv_data$segments, caption = "CNV Segments")
```

```{r cnv_unavailable, eval=!has_cnv}
cat("No CNV analysis results available.")
```

## Frequency Plot

```{r cnv_freq, eval=has_cnv}
p <- resolve_plot_path(cnv_data$frequency_plot, cnv_dir)
embed_img(p)
```

## Individual Sample Profiles

```{r cnv_samples, eval=has_cnv && !is.null(cnv_data$sample_results)}
plots_found <- 0L
for (res in cnv_data$sample_results) {
  if (!is.null(res$plot_file)) {
    p <- resolve_plot_path(res$plot_file, cnv_dir)
    if (!is.null(p)) {
      cat("### Sample:", res$sample_id, "\\n\\n")
      embed_img(p)
      plots_found <- plots_found + 1L
    }
  }
}
if (plots_found == 0L) {
  cat(sprintf("*No individual CNV plots found (expected %d samples)*\\n\\n",
              length(cnv_data$sample_results)))
}
```
'

  rmd_content <- paste0(yaml_header, rmd_body)
  rmd_file <- file.path(output_dir, "methylation_analysis_report.Rmd")
  writeLines(rmd_content, rmd_file)
  return(rmd_file)
}

#' Generate simple text report
#'
#' @param qc_results QC results
#' @param dim_reduction Dimensionality reduction results
#' @param cnv_data CNV analysis results
#' @param sample_info Sample information data frame
#' @return Character vector with report text
generate_text_report <- function(qc_results, dim_reduction, cnv_data, sample_info) {
  report_lines <- c(
    "=================================",
    "Methylation Array Analysis Report",
    "=================================",
    paste("Generated on:", format(Sys.time(), "%Y-%m-%d %H:%M:%S")),
    "",
    "Overview",
    "--------",
    paste("Number of samples:", if(!is.null(sample_info)) nrow(sample_info) else "Not available"),
    ""
  )

  if (!is.null(qc_results)) {
    report_lines <- c(report_lines,
      "Quality Control Summary",
      "----------------------",
      paste("Total samples processed:", length(c(qc_results$passed_samples, qc_results$failed_samples))),
      paste("Samples passing QC:", length(qc_results$passed_samples)),
      paste("Samples failing QC:", length(qc_results$failed_samples)),
      ""
    )
  }

  if (!is.null(cnv_data)) {
    report_lines <- c(report_lines,
      "Copy Number Variation Analysis Summary",
      "------------------------------------",
      paste("Method:", if (!is.null(cnv_data$method)) cnv_data$method else "unknown"),
      paste("Number of segments:", if (!is.null(cnv_data$segments)) nrow(cnv_data$segments) else "unknown"),
      ""
    )
  }

  return(report_lines)
}

#' Create interactive plots for various analysis results
#'
#' @param results Analysis results
#' @param output_dir Output directory for plots
#' @return List of interactive plot paths
create_interactive_plots <- function(results, output_dir = ".") {
  plots <- list()

  has_plotly <- requireNamespace("plotly", quietly = TRUE)
  has_htmlwidgets <- requireNamespace("htmlwidgets", quietly = TRUE)

  if (!has_plotly || !has_htmlwidgets) {
    message("Packages 'plotly' and 'htmlwidgets' required for interactive plots.")
    return(plots)
  }

  return(plots)
}
