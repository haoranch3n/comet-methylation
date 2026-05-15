#!/usr/bin/env bash
#BSUB -q priority
#BSUB -n 4
#BSUB -R "rusage[mem=64GB]"
#BSUB -W 240
#BSUB -J meqtrack_smoke_epic1
#BSUB -o smoke_test_epic1_%J.out
#BSUB -e smoke_test_epic1_%J.err

PROJECT_DIR="/research_jude/rgs01_jude/dept/DNB/core_operations/ImageAnalysis/Core/Haoran/comet-methylation"
cd "$PROJECT_DIR"

module purge 2>/dev/null || true

export PATH="/home/hchen19/miniconda3/envs/meqtrack/bin:$PATH"
export CONDA_PREFIX="/home/hchen19/miniconda3/envs/meqtrack"
export R_HOME="/home/hchen19/miniconda3/envs/meqtrack/lib/R"

echo "=== Environment check ==="
echo "Date: $(date)"
echo "R: $(which R)"
echo "R version: $(R --version | head -1)"
echo "GCC: $(gcc --version | head -1)"
echo "Hostname: $(hostname)"

# ── Install yamapData (only once; skip if already installed) ──────────────────
echo ""
echo "=== Installing yamapData ==="
R --no-save --quiet <<'RINSTALL'
  options(repos = c(CRAN = "https://cloud.r-project.org"))
  renv::load()

  if (!requireNamespace("yamapData", quietly = TRUE)) {
    message("Installing yamapData from local tar...")
    install.packages(
      "yamapData_0.0.3.tar",
      repos  = NULL,
      type   = "source",
      lib    = .libPaths()[1]
    )
    message("yamapData installed OK")
  } else {
    message("yamapData already installed, skipping.")
  }

  # Verify
  stopifnot(requireNamespace("yamapData", quietly = TRUE))
  message("yamapData version: ", packageVersion("yamapData"))
RINSTALL

echo ""
echo "=== Running smoke test: EPIC 1-sample ==="
echo "Start: $(date)"

bash run_with_profiling.sh \
  --input  data/example/samplesheet_epic_1sample.csv \
  --output output/epic_1sample \
  --array_type EPIC \
  --threads 4 \
  --step all

EXIT_CODE=$?

echo ""
echo "=== Smoke test finished ==="
echo "End: $(date)"
echo "Exit code: $EXIT_CODE"

if [ $EXIT_CODE -eq 0 ]; then
  echo ""
  echo "=== Output files ==="
  find output/epic_1sample -type f | sort
  echo ""
  echo "=== Memory summary ==="
  if [ -f output/epic_1sample/memory_profile.csv ]; then
    awk -F, 'NR>1 && $3+0>0 {if($3>max)max=$3} END{printf "Peak RSS: %.1f MB\n", max}' \
      output/epic_1sample/memory_profile.csv
  fi
  if [ -f output/epic_1sample/timing.txt ]; then
    cat output/epic_1sample/timing.txt
  fi
fi

echo "=== LSF job finished: $(date) ==="
exit $EXIT_CODE
