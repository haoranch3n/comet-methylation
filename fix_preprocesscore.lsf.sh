#!/usr/bin/env bash
#BSUB -q priority
#BSUB -n 2
#BSUB -R "rusage[mem=16GB]"
#BSUB -W 60
#BSUB -J meqtrack_fix_preprocess
#BSUB -o fix_preprocesscore_%J.out
#BSUB -e fix_preprocesscore_%J.err

PROJECT_DIR="/research_jude/rgs01_jude/dept/DNB/core_operations/ImageAnalysis/Core/Haoran/comet-methylation"
cd "$PROJECT_DIR"

module purge 2>/dev/null || true

export PATH="/home/hchen19/miniconda3/envs/meqtrack/bin:$PATH"
export CONDA_PREFIX="/home/hchen19/miniconda3/envs/meqtrack"
export R_HOME="/home/hchen19/miniconda3/envs/meqtrack/lib/R"

echo "=== Reinstalling preprocessCore with threading disabled ==="
echo "Date: $(date)"
echo "R: $(which R)"

R --no-save --quiet <<'RFIX'
  options(repos = c(CRAN = "https://cloud.r-project.org"))
  renv::load()

  message("Removing existing preprocessCore...")
  tryCatch(
    remove.packages("preprocessCore"),
    error = function(e) message("preprocessCore not found, installing fresh")
  )

  message("Installing preprocessCore without threading...")
  BiocManager::install(
    "preprocessCore",
    configure.args = "--disable-threading",
    force          = TRUE,
    ask            = FALSE,
    update         = FALSE
  )

  message("Verifying...")
  library(preprocessCore)
  message("preprocessCore version: ", packageVersion("preprocessCore"))

  # Quick sanity check: normalize a small matrix
  m <- matrix(rnorm(100), nrow = 10)
  res <- normalize.quantiles(m)
  stopifnot(is.matrix(res))
  message("normalize.quantiles test: OK")
RFIX

echo "=== Fix job finished: $(date) ==="
