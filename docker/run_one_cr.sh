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
# General configuration
# --------------------------------------------------------------------------

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

PROBE_TRAJECTORY_FILE=${PROBE_TRAJECTORY_FILE:-/app/exec/trajEarth.dat}

# --------------------------------------------------------------------------
# Select boundary-condition file
#
# Preferred:
#   Kubernetes passes BC_FILE directly.
#
# Fallback:
#   Search BOUNDARY_ROOT/CR_NAME and require exactly one HDF file.
# --------------------------------------------------------------------------

if [[ -n "${BC_FILE:-}" ]]; then

    echo "Using explicitly provided boundary file:"
    echo "  BC_FILE=${BC_FILE}"

    if [[ ! -f "${BC_FILE}" ]]; then
        echo "ERROR: Provided boundary file does not exist:"
        echo "  ${BC_FILE}"
        exit 1
    fi

else

    CR_DIR="${BOUNDARY_ROOT}/${CR_NAME}"

    echo "No explicit BC_FILE was provided."
    echo "Searching directory:"
    echo "  ${CR_DIR}"

    if [[ ! -d "${CR_DIR}" ]]; then
        echo "ERROR: Boundary directory does not exist:"
        echo "  ${CR_DIR}"
        exit 1
    fi

    mapfile -t BC_FILES < <(
        find "${CR_DIR}" \
            -maxdepth 1 \
            -type f \
            \( \
                -iname "*.h5" -o \
                -iname "*.hdf5" -o \
                -iname "*.h4" -o \
                -iname "*.hdf4" -o \
                -iname "*.hdf" \
            \) |
        sort
    )

    if [[ "${#BC_FILES[@]}" -ne 1 ]]; then
        echo "ERROR: Expected exactly one boundary file in:"
        echo "  ${CR_DIR}"
        echo "Found: ${#BC_FILES[@]}"

        printf '  %s\n' "${BC_FILES[@]:-}"

        exit 1
    fi

    BC_FILE="${BC_FILES[0]}"
fi

export BC_FILE

# --------------------------------------------------------------------------
# Output locations
#
# Kubernetes may provide OUTPUT_DIR directly.
# Otherwise, use OUTPUT_ROOT/CR_NAME.
# --------------------------------------------------------------------------

OUTPUT_DIR=${OUTPUT_DIR:-"${OUTPUT_ROOT}/${CR_NAME}"}
RUN_DIR="${OUTPUT_DIR}/run"

# This is the rendered text input passed to FullSphere.exe.
INPUT_CONFIG="${RUN_DIR}/inputs"

mkdir -p "${RUN_DIR}"

PROBE_DATA_FILE=${PROBE_DATA_FILE:-"${RUN_DIR}/probed_data.dat"}

# --------------------------------------------------------------------------
# Validate required files
# --------------------------------------------------------------------------

if [[ ! -f "${TEMPLATE_FILE}" ]]; then
    echo "ERROR: Input template not found:"
    echo "  ${TEMPLATE_FILE}"
    exit 1
fi

if [[ ! -f "${EXECUTABLE}" ]]; then
    echo "ERROR: HelioCubed executable not found:"
    echo "  ${EXECUTABLE}"
    exit 1
fi

if [[ ! -f "${PROBE_TRAJECTORY_FILE}" ]]; then
    echo "ERROR: Probe trajectory file not found:"
    echo "  ${PROBE_TRAJECTORY_FILE}"
    exit 1
fi

# --------------------------------------------------------------------------
# Export values used by inputs.template
# --------------------------------------------------------------------------

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
# Create FullSphere input configuration
# --------------------------------------------------------------------------

envsubst < "${TEMPLATE_FILE}" > "${INPUT_CONFIG}"

echo
echo "======================================================"
echo "HelioCubed case"
echo "======================================================"
echo "CR/case name: ${CR_NAME}"
echo "Boundary file: ${BC_FILE}"
echo "Output directory: ${OUTPUT_DIR}"
echo "Run directory: ${RUN_DIR}"
echo "Input configuration: ${INPUT_CONFIG}"
echo "MPI processes: ${NPROC}"
echo "Restart step: ${RESTART_STEP}"
echo "======================================================"

echo
echo "Boundary file information:"
ls -lh "${BC_FILE}"

echo
echo "Restart setting in generated input:"
grep -n -- "-restartStep" "${INPUT_CONFIG}" || true

# --------------------------------------------------------------------------
# Restart validation
# --------------------------------------------------------------------------

if [[ "${RESTART_STEP}" -gt 0 ]]; then

    CHECKPOINT_FILE="${RUN_DIR}/Checkpoint_${RESTART_STEP}.hdf5"

    if [[ ! -f "${CHECKPOINT_FILE}" ]]; then
        echo "ERROR: Restart step ${RESTART_STEP} was requested,"
        echo "but the checkpoint file does not exist:"
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