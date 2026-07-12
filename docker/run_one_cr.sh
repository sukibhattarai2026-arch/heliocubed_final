#!/bin/bash
set -euo pipefail

BOUNDARY_ROOT=${BOUNDARY_ROOT:-/app/boundary_data}
OUTPUT_ROOT=${OUTPUT_ROOT:-/app/outputs}
CR_NAME=${CR_NAME:?ERROR: CR_NAME is required}
NPROC=${NPROC:-4}

DOMAIN_SIZEX=${DOMAIN_SIZEX:-60}
DOMAIN_SIZEY=${DOMAIN_SIZEY:-60}
DOMAIN_SIZEZ=${DOMAIN_SIZEZ:-40}
BOXSIZE=${BOXSIZE:-10}

MAX_STEP=${MAX_STEP:-5000}
RESTART_STEP=${RESTART_STEP:-0}
OUTPUT_INTERVAL=${OUTPUT_INTERVAL:-5}
CHECKPOINT_INTERVAL=${CHECKPOINT_INTERVAL:-100}
MAX_CHECKPOINT_FILES=${MAX_CHECKPOINT_FILES:-3}

TEMPLATE_FILE=${TEMPLATE_FILE:-/app/exec/inputs.template}
EXECUTABLE=${EXECUTABLE:-/app/exec/FullSphere.exe}

CR_DIR="$BOUNDARY_ROOT/$CR_NAME"

mapfile -t BC_FILES < <(
  find "$CR_DIR" -maxdepth 1 -type f \
  \( \
    -iname "*.h5" -o \
    -iname "*.hdf5" -o \
    -iname "*.h4" -o \
    -iname "*.hdf4" -o \
    -iname "*.hdf" \
  \) | sort
)

if [ "${#BC_FILES[@]}" -ne 1 ]; then
  echo "ERROR: Expected exactly one boundary file in $CR_DIR"
  printf '  %s\n' "${BC_FILES[@]:-}"
  exit 1
fi


BC_FILE="${BC_FILES[0]}"
OUTPUT_DIR="$OUTPUT_ROOT/$CR_NAME"
RUN_DIR="$OUTPUT_DIR/run"
INPUT_FILE="$RUN_DIR/inputs"

mkdir -p "$RUN_DIR"

export BC_FILE OUTPUT_DIR
export DOMAIN_SIZEX DOMAIN_SIZEY DOMAIN_SIZEZ BOXSIZE
export MAX_STEP RESTART_STEP OUTPUT_INTERVAL
export CHECKPOINT_INTERVAL MAX_CHECKPOINT_FILES

PROBE_TRAJECTORY_FILE=${PROBE_TRAJECTORY_FILE:-/app/exec/trajEarth.dat}
PROBE_DATA_FILE=${PROBE_DATA_FILE:-$RUN_DIR/probed_data.dat}

if [ ! -f "$PROBE_TRAJECTORY_FILE" ]; then
    echo "ERROR: Probe trajectory file not found:"
    echo "  $PROBE_TRAJECTORY_FILE"
    exit 1
fi

export PROBE_TRAJECTORY_FILE
export PROBE_DATA_FILE

envsubst < "$TEMPLATE_FILE" > "$INPUT_FILE"


cd "$RUN_DIR"

echo "Running $CR_NAME with $NPROC MPI processes"
echo "Executable: $EXECUTABLE"
echo "Inputs: $INPUT_FILE"

mpirun \
    --allow-run-as-root \
    -n "$NPROC" \
    "$EXECUTABLE" inputs