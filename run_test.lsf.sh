#!/usr/bin/env bash
# Generic test runner — parameters injected at submit time via bsub -env or env vars:
#   TEST_NAME   e.g. epic_4sample
#   SAMPLESHEET e.g. data/example/samplesheet_epic.csv
#   ARRAY_TYPE  e.g. EPIC
#BSUB -q priority
#BSUB -n 4
#BSUB -R "rusage[mem=128GB]"
#BSUB -W 360
#BSUB -o run_test_%J.out
#BSUB -e run_test_%J.err

PROJECT_DIR="/research_jude/rgs01_jude/dept/DNB/core_operations/ImageAnalysis/Core/Haoran/comet-methylation"
cd "$PROJECT_DIR"

module purge 2>/dev/null || true
export PATH="/home/hchen19/miniconda3/envs/meqtrack/bin:$PATH"
export CONDA_PREFIX="/home/hchen19/miniconda3/envs/meqtrack"
export R_HOME="/home/hchen19/miniconda3/envs/meqtrack/lib/R"

echo "=== MeQTrack test: ${TEST_NAME} ==="
echo "Date:        $(date)"
echo "Samplesheet: ${SAMPLESHEET}"
echo "Array type:  ${ARRAY_TYPE}"
echo "Host:        $(hostname)"

bash run_with_profiling.sh \
  --input  "${SAMPLESHEET}" \
  --output "output/${TEST_NAME}" \
  --array_type "${ARRAY_TYPE}" \
  --threads 4 \
  --step all

EXIT_CODE=$?

echo ""
echo "=== Results: ${TEST_NAME} ==="
echo "Exit code: $EXIT_CODE"

if [ -f "output/${TEST_NAME}/timing.txt" ]; then
  cat "output/${TEST_NAME}/timing.txt"
fi

echo "=== Job finished: $(date) ==="
exit $EXIT_CODE
