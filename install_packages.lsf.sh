#!/usr/bin/env bash
#BSUB -q priority
#BSUB -n 4
#BSUB -R "rusage[mem=32GB]"
#BSUB -W 240
#BSUB -J meqtrack_install
#BSUB -o install_packages_%J.out
#BSUB -e install_packages_%J.err

set -euo pipefail

PROJECT_DIR="/research_jude/rgs01_jude/dept/DNB/core_operations/ImageAnalysis/Core/Haoran/comet-methylation"
cd "$PROJECT_DIR"

eval "$(conda shell.bash hook 2>/dev/null)"
module purge 2>/dev/null || true
conda activate meqtrack

echo "=== Environment ==="
which R
R --version | head -1
echo "=== Starting package installation: $(date) ==="

Rscript -e '
cat("R home:", R.home(), "\n")
cat("Lib paths:\n"); cat(.libPaths(), sep="\n"); cat("\n")

# Phase 1: BiocManager
if (!requireNamespace("BiocManager", quietly=TRUE)) {
  renv::install("BiocManager")
}
cat("--- BiocManager ready ---\n")

# Phase 2: Core Bioconductor (heavy compilation)
bioc_pkgs <- c(
  "minfi", "limma", "missMethyl", "matrixStats",
  "DMRcate", "GenomicRanges", "sesame", "Gviz", "snifter",
  "IlluminaHumanMethylation450kanno.ilmn12.hg19",
  "IlluminaHumanMethylationEPICanno.ilm10b4.hg19",
  "IlluminaHumanMethylationEPICv2manifest",
  "IlluminaHumanMethylationEPICv2anno.20a1.hg38",
  "RColorBrewer", "BiocParallel"
)
for (pkg in bioc_pkgs) {
  cat(sprintf("Installing %s...\n", pkg))
  tryCatch(
    BiocManager::install(pkg, update=FALSE, ask=FALSE),
    error = function(e) cat(sprintf("  FAILED: %s\n", conditionMessage(e)))
  )
}
cat("=== Bioconductor packages done ===\n")

# Phase 3: CRAN packages
cran_pkgs <- c(
  "optparse", "data.table", "ggplot2", "plotly", "Rtsne", "umap",
  "dendextend", "circlize", "htmlwidgets", "rmarkdown", "knitr",
  "DT", "yaml", "ggrepel", "stringr", "dplyr", "readr", "scales",
  "ggnewscale", "patchwork", "pryr"
)
for (pkg in cran_pkgs) {
  cat(sprintf("Installing %s...\n", pkg))
  tryCatch(
    install.packages(pkg, repos="https://cran.r-project.org"),
    error = function(e) cat(sprintf("  FAILED: %s\n", conditionMessage(e)))
  )
}
cat("=== CRAN packages done ===\n")

# Phase 4: conumee2 from GitHub
cat("Installing conumee2 from GitHub...\n")
tryCatch({
  if (!requireNamespace("remotes", quietly=TRUE)) install.packages("remotes", repos="https://cran.r-project.org")
  remotes::install_github("hovestadtlab/conumee2", subdir="conumee2", upgrade="never")
  cat("conumee2 installed successfully\n")
}, error = function(e) {
  cat(sprintf("conumee2 FAILED: %s\n", conditionMessage(e)))
})

# Phase 5: yamapData (if tarball exists)
yamap_path <- file.path("data", "yamapData_0.0.3.tar.gz")
if (file.exists(yamap_path)) {
  cat("Installing yamapData from local tarball...\n")
  install.packages(yamap_path, repos=NULL, type="source")
} else {
  cat("WARNING: yamapData_0.0.3.tar.gz not found in data/ - CNV step will not work\n")
}

# Phase 6: Snapshot renv
cat("=== Taking renv snapshot ===\n")
renv::snapshot(prompt=FALSE)

# Phase 7: Verify
cat("\n=== Verification ===\n")
required <- c("minfi", "limma", "sesame", "DMRcate", "matrixStats",
              "GenomicRanges", "ggplot2", "plotly", "Rtsne", "umap",
              "optparse", "data.table", "rmarkdown", "conumee2")
for (pkg in required) {
  ok <- requireNamespace(pkg, quietly=TRUE)
  cat(sprintf("  %-50s %s\n", pkg, ifelse(ok, "OK", "MISSING")))
}
cat("\n=== Installation complete: ", as.character(Sys.time()), " ===\n")
'

echo "=== LSF job finished: $(date) ==="
