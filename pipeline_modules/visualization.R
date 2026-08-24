# Visualization module for methylation array analysis pipeline

#' Generate comprehensive report
#'
#' @param qc_results QC results
#' @param dim_reduction Dimensionality reduction results
#' @param cnv_data CNV analysis results
#' @param reference_projection Reference-projection results (the rp_result
#'   list from run_reference_projection: dataset, projected, class_hints, ...)
#' @param reference_projection_status Why `reference_projection` is NULL, when
#'   it is: "disabled", "no_reference_dir" or "failed". Lets the report say
#'   which, instead of reporting a deliberate skip as a missing result.
#' @param sample_info Sample information data frame
#' @param output_dirs Named list of module output directories (from setup_directories())
#' @param output_dir Output directory for reports
#' @return List of generated report paths
generate_report <- function(qc_results = NULL,
                          dim_reduction = NULL,
                          cnv_data = NULL,
                          reference_projection = NULL,
                          reference_projection_status = NULL,
                          sample_info = NULL,
                          output_dirs = NULL,
                          output_dir = ".") {

  report_files <- list()

  # ------------------------------------------------------------------
  # Check prerequisites for HTML rendering
  # ------------------------------------------------------------------
  has_rmarkdown <- requireNamespace("rmarkdown", quietly = TRUE)

  # R from CRAN ships no pandoc (only RStudio bundles one), so a plain
  # double-click install has none on PATH. setup.R provisions a managed copy
  # via the `pandoc` package in that case; wire it in here. find_pandoc()
  # checks RSTUDIO_PANDOC first, so point it at the managed binary's dir and
  # clear the cache so the new location takes effect.
  if (has_rmarkdown && nchar(rmarkdown::find_pandoc()$dir) == 0 &&
      requireNamespace("pandoc", quietly = TRUE) &&
      isTRUE(tryCatch(pandoc::pandoc_available(), error = function(e) FALSE))) {
    Sys.setenv(RSTUDIO_PANDOC = dirname(pandoc::pandoc_bin()))
    rmarkdown::find_pandoc(cache = FALSE)
    message("Using managed pandoc: ", Sys.getenv("RSTUDIO_PANDOC"))
  }

  has_pandoc    <- has_rmarkdown && nchar(rmarkdown::find_pandoc()$dir) > 0
  has_DT        <- requireNamespace("DT", quietly = TRUE)
  has_knitr     <- requireNamespace("knitr", quietly = TRUE)

  render_html <- has_rmarkdown && has_pandoc && has_DT && has_knitr

  if (!has_rmarkdown) message("Package 'rmarkdown' not available — skipping HTML report.")
  if (has_rmarkdown && !has_pandoc) message("pandoc not found — skipping HTML report. ",
    "On HPC, try: module load pandoc  or set RSTUDIO_PANDOC.")
  if (!has_DT)    message("Package 'DT' not available — skipping HTML report.")
  if (!has_knitr) message("Package 'knitr' not available — skipping HTML report.")

  if (render_html) {
    message("Generating HTML report...")

    # Ensure output dir exists and resolve to an absolute path — rmarkdown::render
    # changes the working directory, so relative paths break mid-render.
    dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)
    abs_output_dir <- normalizePath(output_dir, winslash = "/", mustWork = TRUE)

    # Save all results into a single RData file loaded by the Rmd
    report_data <- list(
      qc_results           = qc_results,
      dim_reduction        = dim_reduction,
      cnv_data             = cnv_data,
      reference_projection = reference_projection,
      # Why the projection section is empty, when it is: "disabled",
      # "no_reference_dir", "failed" or NULL. Without it the report cannot tell
      # a deliberate skip from a failure.
      reference_projection_status = reference_projection_status,
      sample_info          = sample_info,
      output_dirs          = output_dirs,
      generation_time      = Sys.time()
    )
    save(report_data, file = file.path(abs_output_dir, "report_data.RData"))

    # Write the Rmd template (absolute path so pandoc's chdir doesn't break it)
    rmd_file  <- create_report_rmd(abs_output_dir)
    html_file <- file.path(abs_output_dir, "methylation_analysis_report.html")

    # Render — catch errors so a rendering failure never kills the pipeline
    render_ok <- tryCatch({
      rmarkdown::render(
        input       = rmd_file,
        output_file = basename(html_file),
        output_dir  = abs_output_dir,
        intermediates_dir = abs_output_dir,
        knit_root_dir     = abs_output_dir,
        quiet       = FALSE,          # show render progress/errors
        envir       = new.env()       # clean environment for reproducibility
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

  # Always produce a plain-text report as a reliable fallback
  if (is.null(report_files$html)) {
    text_report <- generate_text_report(qc_results, dim_reduction, cnv_data,
                                        sample_info, reference_projection)
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
  # Create the YAML header with proper date formatting
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
---')

  # Create the R Markdown content body
  rmd_body <- '
```{r setup, include=FALSE}
# results = "asis" is load-bearing, not cosmetic. Every explanatory line in
# this report is produced by cat()-ing markdown, and without it knitr wraps
# that output in a verbatim block: the report then renders as console text --
# "## **1 samples passed QC**", "## *Plot not available*", and an unclickable
# "## [Interactive density plot](interactive_density_plot.html)". Chunks that
# genuinely want verbatim output (session info) set results = "markup" on
# themselves.
knitr::opts_chunk$set(echo = FALSE, warning = FALSE, message = FALSE,
                      fig.width = 10, fig.height = 7, results = "asis")
library(ggplot2)
library(DT)
library(knitr)

# Load report data saved by generate_report()
load("report_data.RData")

# ------------------------------------------------------------------
# Helper: resolve a stored plot path to one that actually exists.
# Tries the stored path first, then looks for the file by basename
# inside the known output module directories, then falls back to
# relative paths from the reports directory.
# ------------------------------------------------------------------
resolve_plot_path <- function(stored_path, module_dir = NULL) {
  if (is.null(stored_path) || is.na(stored_path) || !nzchar(stored_path)) return(NULL)

  # 1. Stored path already valid
  if (file.exists(stored_path)) return(stored_path)

  fname <- basename(stored_path)

  # A run made before the PDF -> PNG conversion has the same figure under the
  # other extension. Try the sibling so re-rendering a report over an older
  # output directory still finds its plots instead of printing
  # "*Plot not available*". Mirrors user_upload_cnv_plot_path() in the Shiny
  # layer, which resolves the CNV figure the same way.
  # NOTE: everything from here to the end of rmd_body lives inside a
  # SINGLE-QUOTED R string, so R resolves escape sequences once before the text
  # is ever written to the Rmd. A regex written here with a doubled backslash
  # arrives in the Rmd with a single one, and the setup chunk then dies with
  # "unrecognized escape in character string" -- which is why this comparison
  # uses tools::file_ext() instead of a regex. Keep this region free of
  # backslashes; if you ever need one, it has to be quadrupled.
  .siblings <- function(nm) {
    ext <- tolower(tools::file_ext(nm))
    stem <- tools::file_path_sans_ext(nm)
    if (ext == "png") c(nm, paste0(stem, ".pdf"))
    else if (ext == "pdf") c(nm, paste0(stem, ".png"))
    else nm
  }

  # 2/3. Search every known location, preferring the requested extension over
  # its sibling at each one -- the stored .png first, the legacy .pdf only if no
  # .png exists anywhere.
  for (nm in .siblings(fname)) {
    if (!is.null(module_dir) && nzchar(module_dir)) {
      candidate <- file.path(module_dir, nm)
      if (file.exists(candidate)) return(candidate)
      # Also try one level deeper (e.g. qc/plots/)
      candidate2 <- file.path(module_dir, "plots", nm)
      if (file.exists(candidate2)) return(candidate2)
    }
    for (rel in c(
        file.path("..", "figures", "qc",            nm),
        file.path("..", "figures", "dim_reduction", nm),
        file.path("..", "figures", "cnv",           nm),
        file.path("..", "qc", "plots",              nm),
        file.path("..", "qc",                       nm),
        file.path("..", "dimensionality_reduction", nm),
        file.path("..", "cnv",                      nm),
        file.path("..", "cnv", "plots",             nm),
        file.path("..", "reference_projection",     nm),
        nm
    )) {
      if (file.exists(rel)) return(rel)
    }
  }

  # 4. Return NULL so callers can show "not available" gracefully
  return(NULL)
}

# Emit an italic note. paste0 rather than sprintf so a message that happens to
# contain a percent sign cannot abort the render.
emit_note <- function(...) cat("*", paste0(...), "*", "\n\n", sep = "")

# Emit a figure as markdown instead of via knitr::include_graphics().
# include_graphics() returns a knit_asis object that knitr renders only where
# it is a top-level visible value; print()ing one inside a for loop -- which is
# what the per-sample CNV section did -- writes the raw path and its attributes
# into the report instead of the image. cat()ing markdown works in both
# positions. Returns TRUE when a figure was emitted.
emit_plot <- function(path, module_dir = NULL, missing_note = "Plot not available") {
  p <- resolve_plot_path(path, module_dir)
  if (is.null(p)) {
    emit_note(missing_note)
    return(invisible(FALSE))
  }
  # A PDF cannot be shown inline in an HTML report, so link it rather than
  # emitting an img tag that renders as a broken image.
  if (identical(tolower(tools::file_ext(p)), "pdf")) {
    cat("[Open the figure (PDF)](", p, ")", "\n\n", sep = "")
  } else {
    cat("![](", p, ")", "\n\n", sep = "")
  }
  invisible(TRUE)
}

# Rewrite an absolute path as one relative to the report itself. The links
# below would otherwise expose the server-side results path
# (/mnt/blob/.../results/j_<uuid>/...) inside a document users download and
# forward, and that path means nothing on their machine anyway. knit_root_dir
# is normally the reports directory, but anchor on the recorded reports
# directory when there is one so re-rendering an old report from somewhere else
# still yields ../figures/qc/... instead of a chain of parent hops.
rel_to_report <- function(p) {
  if (is.null(p) || !nzchar(p)) return(p)
  ap <- tryCatch(normalizePath(p, winslash = "/", mustWork = FALSE),
                 error = function(e) p)
  anchor <- report_data$output_dirs$reports
  if (is.null(anchor) || !nzchar(anchor)) anchor <- getwd()
  wd <- tryCatch(normalizePath(anchor, winslash = "/", mustWork = FALSE),
                 error = function(e) NULL)
  if (is.null(wd)) return(ap)
  a <- strsplit(ap, "/", fixed = TRUE)[[1]]
  b <- strsplit(wd, "/", fixed = TRUE)[[1]]
  k <- 0L
  while (k < min(length(a), length(b)) && identical(a[k + 1L], b[k + 1L])) {
    k <- k + 1L
  }
  if (k == 0L) return(ap)
  paste(c(rep("..", length(b) - k), a[-seq_len(k)]), collapse = "/")
}

# Drop columns that hold no value for any sample. Several are NA by
# construction on a single-sample run -- minfi getSex() k-means-clusters X/Y
# intensity ACROSS samples and cannot run on one, and the SNP fingerprint has
# nothing to match against -- and a table of NA columns reads as a broken
# report rather than as a measurement that does not apply. Returns the kept
# frame plus the dropped names, so the report can say what it removed.
drop_empty_cols <- function(df) {
  if (is.null(df) || !is.data.frame(df) || ncol(df) == 0) {
    return(list(df = df, dropped = character(0)))
  }
  keep <- vapply(df, function(x) {
    v <- as.character(x)
    any(!is.na(v) & nzchar(trimws(v)))
  }, logical(1))
  if (!any(keep)) return(list(df = df, dropped = character(0)))
  list(df = df[, keep, drop = FALSE], dropped = colnames(df)[!keep])
}

# Convenience: make a datatable or print a message
show_table <- function(df, caption = "", ...) {
  if (!is.null(df) && is.data.frame(df) && nrow(df) > 0) {
    DT::datatable(df, caption = caption,
                  options = list(pageLength = 10, scrollX = TRUE), ...)
  } else {
    cat("*Table not available*\n\n")
  }
}

# Sample count the analysis steps actually saw: QC-passed samples when QC ran,
# otherwise the samplesheet size. Used below to explain why a step was skipped
# instead of leaving the reader with a bare "not available".
n_pass_qc <- if (!is.null(report_data$qc_results)) {
  length(report_data$qc_results$passed_samples)
} else NA_integer_
n_sheet <- if (!is.null(report_data$sample_info)) nrow(report_data$sample_info) else NA_integer_
n_used  <- if (!is.na(n_pass_qc) && n_pass_qc > 0L) n_pass_qc else n_sheet

# Explain a step that cannot run at this sample count. The minimums are
# properties of the algorithms, not policy: t-SNE needs perplexity >= 1 and
# caps it at (n - 1) / 3, so it needs 4; umap() requires n_neighbors > 1, so 3;
# plot.hclust() cannot draw a single merge, so 3; and the MDS plot is only
# drawn above 3.
emit_too_few <- function(what, need) {
  have <- if (is.na(n_used)) "fewer" else as.character(n_used)
  emit_note(what, " compares samples against each other, so it needs at least ",
            need, " and this run has ", have, ". It was skipped rather than ",
            "failing, and no per-sample result above is affected. Your sample ",
            "is instead placed against the full COMET reference cohort in the ",
            "viewer, which is what this section would otherwise approximate.")
}

# Pull directories from report_data
odirs <- report_data$output_dirs   # may be NULL if pipeline is old
```

# Overview

This report summarises the results of methylation array analysis performed using MeQTrack.

## Sample Information

```{r sample_info}
si_clean <- drop_empty_cols(report_data$sample_info)
show_table(si_clean$df, caption = "Sample Information")
if (length(si_clean$dropped) > 0) {
  emit_note("Columns with no value for any sample were removed here: ",
            paste(si_clean$dropped, collapse = ", "),
            ". On a single-sample run minfi cannot call sex, because its ",
            "estimator clusters X/Y intensity across samples -- read the ",
            "sesame sex call and karyotype in the QC table below instead.")
}
```

# Quality Control {.tabset}

```{r qc_check}
qc <- report_data$qc_results
has_qc <- !is.null(qc)
```

```{r qc_summary, eval=has_qc}
n_pass <- length(qc$passed_samples)
n_fail <- length(qc$failed_samples)
cat(sprintf("**%d sample(s) passed QC** | **%d sample(s) failed QC**\n\n",
            n_pass, n_fail))
if (n_fail > 0) {
  cat("Failed: ", paste(qc$failed_samples, collapse = ", "), "\n\n", sep = "")
}
if (length(qc$gct_failed_samples) > 0) {
  cat("Dropped by the GCT bisulfite-conversion gate: ",
      paste(qc$gct_failed_samples, collapse = ", "), "\n\n", sep = "")
}
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
emit_plot(qc$plots$mean_detection_pvalue, if (!is.null(odirs)) odirs$figures_qc else NULL,
          missing_note = "The detection p-value plot was not produced by this run")
```

## Beta Density

```{r qc_density, eval=has_qc}
emit_plot(qc$plots$beta_density, if (!is.null(odirs)) odirs$figures_qc else NULL,
          missing_note = "The beta density plot was not produced by this run")
```

## Beta Bean Plot

```{r qc_bean, eval=has_qc}
emit_plot(qc$plots$beta_bean, if (!is.null(odirs)) odirs$figures_qc else NULL,
          missing_note = "The beta bean plot was not produced by this run")
```

## MDS Plot

```{r qc_mds, eval=has_qc}
# The MDS plot is only drawn above 3 samples (qc.R), so on the single-sample
# uploads this pipeline mostly serves its absence is the norm. Say why.
if (is.null(qc$plots$mds) && !is.na(n_used) && n_used < 4) {
  emit_too_few("An MDS plot", 4)
} else {
  emit_plot(qc$plots$mds, if (!is.null(odirs)) odirs$figures_qc else NULL,
            missing_note = "The MDS plot was not produced by this run")
}
```

## Interactive Plots

```{r qc_interactive, eval=has_qc}
idens <- resolve_plot_path(qc$plots$interactive_density,
                           if (!is.null(odirs)) odirs$figures_qc else NULL)
imds  <- resolve_plot_path(qc$plots$interactive_mds,
                           if (!is.null(odirs)) odirs$figures_qc else NULL)
# Link the resolved path, not basename(): these widgets are written to
# figures/qc/ while the report lands in reports/, so a bare filename pointed at
# a sibling that does not exist. Even correct, the link only resolves when the
# report is opened inside the results folder -- the HTML itself is
# self-contained and often travels alone -- so say so.
if (!is.null(idens)) {
  cat("[Interactive density plot](", rel_to_report(idens), ")", "\n\n", sep = "")
}
if (!is.null(imds)) {
  cat("[Interactive MDS plot](", rel_to_report(imds), ")", "\n\n", sep = "")
}
if (is.null(idens) && is.null(imds)) {
  if (!is.na(n_used) && n_used < 4) {
    emit_too_few("An interactive MDS plot", 4)
  } else {
    emit_note("Interactive plots were not produced by this run")
  }
} else {
  emit_note("These open the standalone widget files stored alongside this ",
            "report under figures/qc/, so they need the whole results folder ",
            "rather than this HTML file on its own.")
}
```

# Dimensionality Reduction {.tabset}

```{r dr_check}
dr     <- report_data$dim_reduction
has_dr <- !is.null(dr)
dr_dir <- if (!is.null(odirs)) odirs$figures_dim_reduction else NULL
```

## t-SNE

```{r tsne_results, eval=has_dr && !is.null(dr$tsne$coords)}
tsne <- dr$tsne
# coords field (actual name from dim_reduction.R)
coords_df <- tsne$coords
if (!is.null(coords_df) && is.data.frame(coords_df)) {
  show_table(coords_df, caption = "t-SNE Coordinates")
}

emit_plot(file.path(if (!is.null(dr_dir)) dr_dir else ".", "tsne_plot.png"),
          dr_dir, missing_note = "The t-SNE plot was not produced by this run")

if (length(tsne$duplicates) > 0) {
  cat("\n**Duplicate samples removed before t-SNE:**",
      paste(tsne$duplicates, collapse = ", "), "\n\n")
}
```

```{r tsne_unavailable, eval=!has_dr || is.null(dr$tsne$coords)}
if (!is.na(n_used) && n_used < 4) {
  emit_too_few("t-SNE", 4)
} else {
  emit_note("No t-SNE results are available for this run.")
}
```

## UMAP

```{r umap_results, eval=has_dr && !is.null(dr$umap$coords)}
umap_res <- dr$umap
coords_df <- umap_res$coords
if (!is.null(coords_df) && is.data.frame(coords_df)) {
  show_table(coords_df, caption = "UMAP Coordinates")
}

emit_plot(file.path(if (!is.null(dr_dir)) dr_dir else ".", "umap_plot.png"),
          dr_dir, missing_note = "The UMAP plot was not produced by this run")
```

```{r umap_unavailable, eval=!has_dr || is.null(dr$umap$coords)}
if (!is.na(n_used) && n_used < 3) {
  emit_too_few("UMAP", 3)
} else {
  emit_note("No UMAP results are available for this run.")
}
```

## Hierarchical Clustering

```{r hclust_results, eval=has_dr && !is.null(dr$hclust)}
hcl <- dr$hclust
cat(sprintf("**Method:** %s | **Distance:** %s\n\n",
            hcl$method, hcl$distance))

# hclust() joins two samples fine, but plot.hclust() cannot draw a single
# merge, so a two-sample run has results and no figure.
if (!is.na(n_used) && n_used < 3) {
  emit_too_few("A dendrogram", 3)
} else {
  emit_plot(file.path(if (!is.null(dr_dir)) dr_dir else ".", "hclust_dendrogram.png"),
            dr_dir, missing_note = "The dendrogram was not produced by this run")
}
```

```{r hclust_unavailable, eval=!has_dr || is.null(dr$hclust)}
if (!is.na(n_used) && n_used < 2) {
  emit_too_few("Hierarchical clustering", 2)
} else {
  emit_note("No hierarchical clustering results are available for this run.")
}
```

# Reference Projection {.tabset}

```{r refproj_check}
rp     <- report_data$reference_projection
has_rp <- !is.null(rp)
rp_dir <- if (!is.null(odirs)) odirs$reference_projection else NULL
```

```{r refproj_summary, eval=has_rp}
rp_name <- if (!is.null(rp$label)) rp$label else rp$dataset
cat(sprintf("Query samples projected onto the **%s** reference (%s reference samples). Each sample is assigned its nearest reference tumour group by a k-NN vote in the embedding.\n\n",
            rp_name,
            if (!is.null(rp$ref_meta)) nrow(rp$ref_meta) else "?"))
```

## Class Hints

```{r refproj_table, eval=has_rp}
proj <- as.data.frame(rp$projected)
ch   <- rp$class_hints
if (!is.null(ch)) {
  ch  <- ch[match(proj$Sample, ch$Sample), , drop = FALSE]
  tbl <- data.frame(
    Sample          = proj$Sample,
    tSNE1           = round(proj$tSNE1, 2),
    tSNE2           = round(proj$tSNE2, 2),
    `Nearest class` = ch$nearest_class,
    Confidence      = sprintf("%.0f%%", 100 * ch$confidence),
    `Top classes`   = ch$top_classes,
    Ambiguous       = ifelse(ch$ambiguous %in% TRUE, "yes", ""),
    Distant         = ifelse(ch$distant_from_reference %in% TRUE, "yes", ""),
    check.names     = FALSE
  )
} else {
  tbl <- data.frame(Sample = proj$Sample,
                    tSNE1  = round(proj$tSNE1, 2),
                    tSNE2  = round(proj$tSNE2, 2),
                    check.names = FALSE)
}
show_table(tbl, caption = "Per-sample nearest reference tumour class")
```

```{r refproj_unavailable, eval=!has_rp}
# Distinguish "switched off for this run" from "tried and failed". The COMET
# web upload deliberately disables this step -- the platform runs its own
# top-K projection against the reference snapshot after the pipeline exits and
# renders it in the viewer -- so the previous flat "No reference projection
# results available." was read as a broken section on every web job.
rp_status <- report_data$reference_projection_status
if (identical(rp_status, "disabled")) {
  emit_note("Reference projection is turned off for this run. On the COMET ",
            "website that is deliberate: the platform projects your sample ",
            "onto the reference cohort itself once the pipeline finishes and ",
            "shows it as a star in the viewer, using the same embedding the ",
            "viewer draws. Nothing failed, and nothing is missing from the ",
            "results folder.")
} else if (identical(rp_status, "no_reference_dir")) {
  emit_note("Reference projection was skipped because the reference data ",
            "directory was not present for this run.")
} else if (identical(rp_status, "failed")) {
  emit_note("Reference projection was attempted but did not complete; see ",
            "pipeline_log.txt for the reason. Every other section of this ",
            "report is unaffected.")
} else {
  emit_note("No reference projection results are available for this run.")
}
```

## Projection Plot

```{r refproj_plot, eval=has_rp}
# Interactive projection: hover a query diamond to read its ID, samplesheet
# metadata (diagnosis + demographics) and k-NN class hint. Falls back to the
# static PDF when plotly is unavailable. Tooltip mirrors the Shiny app
# (.refproj_query_hover in app/R/dimred_module.R) — keep the two in sync.
if (requireNamespace("plotly", quietly = TRUE)) {
  proj <- as.data.frame(rp$projected)
  si   <- report_data$sample_info
  ch   <- rp$class_hints
  excl <- c("Sample_ID", "Sentrix_ID", "Sentrix_Position",
            "Basename", "Array", "Slide", "Pool_ID")

  hov <- sprintf("<b>%s</b>", proj$Sample)
  if (!is.null(si) && nrow(si) > 0) {
    key <- if ("Sample_ID" %in% colnames(si)) "Sample_ID" else colnames(si)[1]
    idx <- match(proj$Sample, as.character(si[[key]]))
    for (col in setdiff(colnames(si), excl)) {
      val <- as.character(si[[col]][idx])
      val[is.na(val) | !nzchar(val)] <- "—"
      hov <- paste0(hov, sprintf("<br>%s: %s", col, val))
    }
  }
  if (!is.null(ch)) {
    chm  <- ch[match(proj$Sample, ch$Sample), , drop = FALSE]
    flag <- paste0(ifelse(chm$ambiguous %in% TRUE, " [ambiguous]", ""),
                   ifelse(chm$distant_from_reference %in% TRUE, " [distant]", ""))
    hov  <- paste0(hov, sprintf("<br>Nearest class: %s (%.0f%%)%s",
                                chm$nearest_class, 100 * chm$confidence, flag))
  }
  proj$hover <- paste0(hov, sprintf("<br>t-SNE 1: %.2f | t-SNE 2: %.2f",
                                    proj$tSNE1, proj$tSNE2))

  fig <- plotly::plot_ly()
  rm_ <- rp$ref_meta
  if (!is.null(rm_)) {
    rm_ <- as.data.frame(rm_)
    rm_$tumor_group <- factor(rm_$tumor_group)
    cmap <- unlist(tapply(rm_$color, rm_$tumor_group, function(x) x[[1]]))
    ok <- vapply(cmap, function(cc) !is.na(cc) &&
                   tryCatch({ grDevices::col2rgb(cc); TRUE },
                            error = function(e) FALSE), logical(1))
    if (any(!ok)) cmap[!ok] <- grDevices::rainbow(sum(!ok))
    fig <- plotly::add_markers(fig, data = rm_, x = ~tSNE1, y = ~tSNE2,
             color = ~tumor_group, colors = cmap,
             marker = list(size = 9, opacity = 0.75,
                           line = list(width = 1, color = "#7F7F7F")),
             text = ~tumor_group,
             hovertemplate = "Reference: %{text}<extra></extra>")
  }
  fig <- plotly::add_markers(fig, data = proj, x = ~tSNE1, y = ~tSNE2,
           name = "Your samples",
           marker = list(size = 8, symbol = "diamond", color = "#111111",
                         line = list(width = 1.2, color = "#ffffff")),
           text = ~hover, hovertemplate = "%{text}<extra>Your sample</extra>")
  plotly::layout(fig, xaxis = list(title = "t-SNE 1"),
                 yaxis = list(title = "t-SNE 2"),
                 legend = list(itemsizing = "constant"))
} else {
  p <- resolve_plot_path(rp$pdf, rp_dir)
  if (!is.null(p)) knitr::include_graphics(p) else cat("*Projection plot not available*\n\n")
}
```

# Copy Number Variation Analysis {.tabset}

```{r cnv_check}
cnv_data <- report_data$cnv_data
has_cnv  <- !is.null(cnv_data)
cnv_dir  <- if (!is.null(odirs)) odirs$figures_cnv else NULL
```

## CNV Segments

```{r cnv_segments, eval=has_cnv}
cat(sprintf("CNV analysis method: **%s**\n\n",
            if (!is.null(cnv_data$method)) cnv_data$method else "unknown"))
show_table(cnv_data$segments, caption = "CNV Segments")
```

```{r cnv_unavailable, eval=!has_cnv}
cat("No CNV analysis results available.")
```

## Frequency Plot

```{r cnv_freq, eval=has_cnv}
emit_plot(cnv_data$frequency_plot, cnv_dir,
          missing_note = "The CNV frequency plot was not produced by this run")
```

## Individual Sample Profiles

```{r cnv_samples, eval=has_cnv && !is.null(cnv_data$sample_results)}
# emit_plot() rather than print(include_graphics()): inside this loop the
# latter printed the path and its knit_asis attributes as text, so the
# per-sample CNV profiles -- one PNG per sample, and the most useful CNV
# output in the report -- never appeared as images at all.
plots_found <- 0L
for (res in cnv_data$sample_results) {
  if (!is.null(res$plot_file)) {
    cat("### Sample: ", res$sample_id, "\n\n", sep = "")
    if (emit_plot(res$plot_file, cnv_dir,
                  missing_note = "The CNV profile figure for this sample was not found")) {
      plots_found <- plots_found + 1L
    }
  }
}
if (plots_found == 0L) {
  emit_note("No individual CNV profile figures were found (expected ",
            length(cnv_data$sample_results), ").")
}
```

# Session Information

```{r session_info_time}
cat("Report generated on: ",
    format(report_data$generation_time, "%Y-%m-%d %H:%M:%S"), "\n\n", sep = "")
```

```{r session_info, results="markup"}
sessionInfo()
```
'

  # Combine header and body
  rmd_content <- paste0(yaml_header, rmd_body)

  # Write the Rmd file
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
#' @param reference_projection Reference-projection results (rp_result), optional
#' @return Character vector with report text
generate_text_report <- function(qc_results, dim_reduction, cnv_data,
                                 sample_info, reference_projection = NULL) {
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

  # QC summary
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

  # Dimensionality reduction summary
  if (!is.null(dim_reduction)) {
    report_lines <- c(report_lines,
      "Dimensionality Reduction Summary",
      "-------------------------------"
    )

    if (!is.null(dim_reduction$tsne)) {
      n_samp <- if (!is.null(dim_reduction$tsne$coords)) nrow(dim_reduction$tsne$coords) else "unknown"
      report_lines <- c(report_lines,
        paste("t-SNE: samples =", n_samp),
        ""
      )
    }

    if (!is.null(dim_reduction$umap)) {
      n_samp <- if (!is.null(dim_reduction$umap$coords)) nrow(dim_reduction$umap$coords) else "unknown"
      report_lines <- c(report_lines,
        paste("UMAP: samples =", n_samp),
        ""
      )
    }

    if (!is.null(dim_reduction$hclust)) {
      report_lines <- c(report_lines,
        paste("Hierarchical clustering: method =", dim_reduction$hclust$method,
              "| distance =", dim_reduction$hclust$distance),
        ""
      )
    }
  }

  # CNV analysis summary
  if (!is.null(cnv_data)) {
    report_lines <- c(report_lines,
      "Copy Number Variation Analysis Summary",
      "------------------------------------",
      paste("Method:", if (!is.null(cnv_data$method)) cnv_data$method else "unknown"),
      paste("Number of segments:", if (!is.null(cnv_data$segments)) nrow(cnv_data$segments) else "unknown"),
      ""
    )
  }

  # Reference projection summary
  if (!is.null(reference_projection) &&
      !is.null(reference_projection$class_hints)) {
    ch <- reference_projection$class_hints
    report_lines <- c(report_lines,
      "Reference Projection Summary",
      "---------------------------",
      paste("Reference dataset:",
            if (!is.null(reference_projection$label))
              reference_projection$label else reference_projection$dataset),
      paste("Samples projected:", nrow(ch)),
      ""
    )
    for (i in seq_len(nrow(ch))) {
      report_lines <- c(report_lines,
        sprintf("  %s -> %s (%.0f%% confidence)%s",
                ch$Sample[i], ch$nearest_class[i], 100 * ch$confidence[i],
                if (isTRUE(ch$ambiguous[i])) " [ambiguous]" else ""))
    }
    report_lines <- c(report_lines, "")
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

  # Check if required packages are available
  has_plotly <- requireNamespace("plotly", quietly = TRUE)
  has_htmlwidgets <- requireNamespace("htmlwidgets", quietly = TRUE)

  if (!has_plotly || !has_htmlwidgets) {
    message("Packages 'plotly' and 'htmlwidgets' required for interactive plots.")
    return(plots)
  }

  return(plots)
}
