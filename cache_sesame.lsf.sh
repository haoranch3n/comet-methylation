#!/usr/bin/env bash
#BSUB -q priority
#BSUB -n 2
#BSUB -R "rusage[mem=16GB]"
#BSUB -W 120
#BSUB -J meqtrack_sesame_cache
#BSUB -o cache_sesame_%J.out
#BSUB -e cache_sesame_%J.err

PROJECT_DIR="/research_jude/rgs01_jude/dept/DNB/core_operations/ImageAnalysis/Core/Haoran/comet-methylation"
cd "$PROJECT_DIR"

module purge 2>/dev/null || true

export PATH="/home/hchen19/miniconda3/envs/meqtrack/bin:$PATH"
export CONDA_PREFIX="/home/hchen19/miniconda3/envs/meqtrack"
export R_HOME="/home/hchen19/miniconda3/envs/meqtrack/lib/R"

echo "=== Caching sesame ExperimentHub data ==="
echo "Date: $(date)"
echo "R: $(which R)"

R --no-save --quiet <<'RCACHE'
  options(repos = c(CRAN = "https://cloud.r-project.org"))
  renv::load()

  message("Loading sesame...")
  library(sesame)
  library(ExperimentHub)

  message("Caching all sesame data (this may take a while)...")
  sesameDataCache()

  message("Verifying idatSignature is available...")
  # Quick test that the signature data can be fetched
  sig <- sesameData::sesameDataGet("idatSignature")
  message("idatSignature OK, length: ", length(sig))

  message("=== sesame data cache complete ===")
RCACHE

echo "=== Cache job finished: $(date) ==="
