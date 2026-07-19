#!/bin/bash
set -Eeuo pipefail

trap '
    STATUS=$?
    echo "ERROR: run_one_cr.sh failed"
    echo "Line: ${LINENO}"
    echo "Command: ${BASH_COMMAND}"
    echo "Exit code: ${STATUS}"
' ERR

# --------------------------------------------------------------------------
# Required values passed by the Kubernetes Job
# --------------------------------------------------------------------------

CR_NAME=${CR_NAME:?ERROR: CR_NAME is required}
BC_FILE=${BC_FILE:?ERROR: BC_FILE is required}
OUTPUT_DIR=${OUTPUT_DIR:?ERROR: OUTPUT_DIR is required}

# --------------------------------------------------------------------------
# Simulation configuration
# --------------------------------------------------------------------------

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

PROBE_TRAJECTORY_FILE=${PROBE_TRAJECTORY_FILE:-/app/exec/trajEarth.dat}

# --------------------------------------------------------------------------
# Validate required files
# --------------------------------------------------------------------------

if [[ ! -f "${BC_FILE}" ]]; then
    echo "ERROR: Boundary-condition file does not exist:"
    echo "  ${BC_FILE}"
    exit 1
fi

if [[ ! -f "${TEMPLATE_FILE}" ]]; then
    echo "ERROR: Input template does not exist:"
    echo "  ${TEMPLATE_FILE}"
    exit 1
fi

if [[ ! -f "${EXECUTABLE}" ]]; then
    echo "ERROR: HelioCubed executable does not exist:"
    echo "  ${EXECUTABLE}"
    exit 1
fi

if [[ ! -f "${PROBE_TRAJECTORY_FILE}" ]]; then
    echo "ERROR: Probe trajectory file does not exist:"
    echo "  ${PROBE_TRAJECTORY_FILE}"
    exit 1
fi

# --------------------------------------------------------------------------
# Output paths
# --------------------------------------------------------------------------

RUN_DIR="${OUTPUT_DIR}/run"
INPUT_CONFIG="${RUN_DIR}/inputs"
PROBE_DATA_FILE=${PROBE_DATA_FILE:-"${RUN_DIR}/probed_data.dat"}

mkdir -p "${RUN_DIR}"

# --------------------------------------------------------------------------
# Export values used inside inputs.template
# --------------------------------------------------------------------------

export BC_FILE
export OUTPUT_DIR

export DOMAIN_SIZEX
export DOMAIN_SIZEY
export DOMAIN_SIZEZ
export BOXSIZE

export MAX_STEP
export RESTART_STEP
export OUTPUT_INTERVAL
export CHECKPOINT_INTERVAL
export MAX_CHECKPOINT_FILES

export PROBE_TRAJECTORY_FILE
export PROBE_DATA_FILE

# --------------------------------------------------------------------------
# Generate the HelioCubed input configuration
# --------------------------------------------------------------------------

envsubst < "${TEMPLATE_FILE}" > "${INPUT_CONFIG}"

echo
echo "======================================================"
echo "HelioCubed simulation"
echo "======================================================"
echo "Case name: ${CR_NAME}"
echo "Boundary file: ${BC_FILE}"
echo "Output directory: ${OUTPUT_DIR}"
echo "Run directory: ${RUN_DIR}"
echo "Generated input: ${INPUT_CONFIG}"
echo "MPI processes: ${NPROC}"
echo "Restart step: ${RESTART_STEP}"
echo "======================================================"

echo
echo "Boundary file:"
ls -lh "${BC_FILE}"

echo
echo "Boundary reference in generated input:"
grep -n -- "${BC_FILE}" "${INPUT_CONFIG}" || true

echo
echo "Restart configuration:"
grep -n -- "-restartStep" "${INPUT_CONFIG}" || true

# --------------------------------------------------------------------------
# Validate restart configuration
# --------------------------------------------------------------------------

if [[ "${RESTART_STEP}" -gt 0 ]]; then
    CHECKPOINT_FILE="${RUN_DIR}/Checkpoint_${RESTART_STEP}.hdf5"

    if [[ ! -f "${CHECKPOINT_FILE}" ]]; then
        echo "ERROR: Restart step ${RESTART_STEP} was requested,"
        echo "but this checkpoint does not exist:"
        echo "  ${CHECKPOINT_FILE}"
        exit 1
    fi

    echo "Restarting from:"
    echo "  ${CHECKPOINT_FILE}"
else
    echo "Starting a new simulation."
fi

# --------------------------------------------------------------------------
# Run HelioCubed
# --------------------------------------------------------------------------

cd "${RUN_DIR}"

mpirun \
    --allow-run-as-root \
    -n "${NPROC}" \
    "${EXECUTABLE}" \
    inputs