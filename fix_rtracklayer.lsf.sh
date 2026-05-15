#!/usr/bin/env bash
#BSUB -q priority
#BSUB -n 4
#BSUB -R "rusage[mem=32GB]"
#BSUB -W 120
#BSUB -J meqtrack_fix
#BSUB -o fix_rtracklayer_%J.out
#BSUB -e fix_rtracklayer_%J.err

PROJECT_DIR="/research_jude/rgs01_jude/dept/DNB/core_operations/ImageAnalysis/Core/Haoran/comet-methylation"
cd "$PROJECT_DIR"

module purge 2>/dev/null || true

# Activate conda without relying on shell hooks
export PATH="/home/hchen19/miniconda3/envs/meqtrack/bin:$PATH"
export CONDA_PREFIX="/home/hchen19/miniconda3/envs/meqtrack"
export R_HOME="/home/hchen19/miniconda3/envs/meqtrack/lib/R"

echo "=== GCC version ==="
x86_64-conda-linux-gnu-cc --version | head -1
echo "=== R version ==="
R --version | head -1
echo "=== Starting fix install: $(date) ==="

Rscript -e '
cat("R home:", R.home(), "\n")
cat("Lib paths:\n"); cat(.libPaths(), sep="\n"); cat("\n")

# Remove any leftover broken packages
broken_dirs <- list.files(
  file.path(.libPaths()[1]),
  pattern = "^00LOCK",
  full.names = TRUE
)
if (length(broken_dirs) > 0) {
  cat("Removing lock dirs:", broken_dirs, "\n")
  unlink(broken_dirs, recursive = TRUE)
}

# Remove broken Rhdf5lib if present
rhdf5lib_path <- file.path(.libPaths()[1], "Rhdf5lib")
if (dir.exists(rhdf5lib_path) && !file.exists(file.path(rhdf5lib_path, "DESCRIPTION"))) {
  cat("Removing broken Rhdf5lib\n")
  unlink(rhdf5lib_path, recursive = TRUE)
}

# The key fix: install rtracklayer and its full dependency chain
# GCC is now 14.3 so the UCSC code should compile
BiocManager::install(c(
  "rtracklayer",
  "GenomicFeatures",
  "bumphunter",
  "BSgenome",
  "VariantAnnotation",
  "ensembldb",
  "biovizBase",
  "FDb.InfiniumMethylation.hg19",
  "TxDb.Hsapiens.UCSC.hg19.knownGene",
  "methylumi",
  "minfi",
  "missMethyl",
  "Gviz",
  "DMRcate",
  "IlluminaHumanMethylation450kanno.ilmn12.hg19",
  "IlluminaHumanMethylationEPICanno.ilm10b4.hg19",
  "IlluminaHumanMethylationEPICv2manifest",
  "IlluminaHumanMethylationEPICv2anno.20a1.hg38",
  "snifter"
), update = FALSE, ask = FALSE, force = TRUE)

cat("\n=== Verification ===\n")
required <- c(
  "rtracklayer", "GenomicFeatures", "bumphunter", "minfi",
  "missMethyl", "Gviz", "DMRcate", "sesame", "conumee2",
  "limma", "matrixStats", "GenomicRanges", "BiocParallel",
  "IlluminaHumanMethylation450kanno.ilmn12.hg19",
  "IlluminaHumanMethylationEPICanno.ilm10b4.hg19",
  "IlluminaHumanMethylationEPICv2manifest",
  "IlluminaHumanMethylationEPICv2anno.20a1.hg38",
  "ggplot2", "plotly", "Rtsne", "umap", "optparse", "data.table",
  "rmarkdown", "stringr", "snifter"
)
results <- sapply(required, function(pkg) {
  requireNamespace(pkg, quietly = TRUE)
})
for (pkg in names(results)) {
  cat(sprintf("  %-55s %s\n", pkg, ifelse(results[pkg], "OK", "MISSING")))
}

missing <- names(results[!results])
if (length(missing) > 0) {
  cat("\nFAILED packages:", paste(missing, collapse = ", "), "\n")
  quit(status = 1)
} else {
  cat("\nAll packages OK!\n")
}

# Snapshot renv
cat("=== Taking renv snapshot ===\n")
renv::snapshot(prompt = FALSE)
cat("=== renv snapshot complete ===\n")
cat("=== Fix install finished:", as.character(Sys.time()), "===\n")
'

echo "=== LSF job finished: $(date) ==="
