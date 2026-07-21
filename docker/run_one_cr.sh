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
TSTOP=${TSTOP:-20000000}
CFL=${CFL:-0.6}
GAMMA=${GAMMA:-1.5}

DOMAIN_SIZEX=${DOMAIN_SIZEX:-60}
DOMAIN_SIZEY=${DOMAIN_SIZEY:-60}
DOMAIN_SIZEZ=${DOMAIN_SIZEZ:-40}

MAX_STEP=${MAX_STEP:-5000}
RESTART_STEP=${RESTART_STEP:-0}
OUTPUT_INTERVAL=${OUTPUT_INTERVAL:-5}
CHECKPOINT_INTERVAL=${CHECKPOINT_INTERVAL:-100}
MAX_CHECKPOINT_FILES=${MAX_CHECKPOINT_FILES:-3}
BOXSIZE=${BOXSIZE:-10}

SPH_INNER_BC_HDF5=${SPH_INNER_BC_HDF5:-1}
LIMITER_APPLY=${LIMITER_APPLY:-1}
TAKEDIVBSTEP=${TAKEDIVBSTEP:-1}
TIME_INTEGRATOR_TYPE=${TIME_INTEGRATOR_TYPE:-1}
RIEMANN_SOLVER_TYPE=${RIEMANN_SOLVER_TYPE:-2}
ENTROPY_FIX_COEFF=${ENTROPY_FIX_COEFF:-0.3}
INITIALIZE_IN_SPHERICAL_COORDS=${INITIALIZE_IN_SPHERICAL_COORDS:-1}
OUTPUT_IN_SPHERICAL_COORDS=${OUTPUT_IN_SPHERICAL_COORDS:-1}

R_IN=${R_IN:-0.1}
R_OUT=${R_OUT:-1.2}
C_RAD=${C_RAD:-1.0}

BC_START_TIME=${BC_START_TIME:-2024.206170309654}
BC_CADENCE=${BC_CADENCE:-6.0}
BC_FRAME_ROTATE=${BC_FRAME_ROTATE:-0}
PROBE_CADENCE=${PROBE_CADENCE:-3600}

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

export BC_FILE OUTPUT_DIR

export TSTOP CFL GAMMA
export DOMAIN_SIZEX DOMAIN_SIZEY DOMAIN_SIZEZ
export MAX_STEP RESTART_STEP OUTPUT_INTERVAL
export CHECKPOINT_INTERVAL MAX_CHECKPOINT_FILES BOXSIZE

export SPH_INNER_BC_HDF5 LIMITER_APPLY TAKEDIVBSTEP
export TIME_INTEGRATOR_TYPE RIEMANN_SOLVER_TYPE ENTROPY_FIX_COEFF
export INITIALIZE_IN_SPHERICAL_COORDS OUTPUT_IN_SPHERICAL_COORDS

export R_IN R_OUT C_RAD
export BC_START_TIME BC_CADENCE BC_FRAME_ROTATE PROBE_CADENCE

export PROBE_TRAJECTORY_FILE PROBE_DATA_FILE

# --------------------------------------------------------------------------
# Generate the HelioCubed input configuration
# --------------------------------------------------------------------------

envsubst < "${TEMPLATE_FILE}" > "${INPUT_CONFIG}"

echo
echo "======================================================"
echo "HelioCubed simulation"
echo "======================================================"
echo "Case name:                 ${CR_NAME}"
echo "Boundary file:             ${BC_FILE}"
echo "Output directory:          ${OUTPUT_DIR}"
echo "Run directory:             ${RUN_DIR}"
echo "Generated input:           ${INPUT_CONFIG}"
echo "MPI processes:             ${NPROC}"
echo "Simulation stop time:      ${TSTOP} s"
echo "CFL:                       ${CFL}"
echo "Gamma:                     ${GAMMA}"
echo "Domain cells (r,t,p):      ${DOMAIN_SIZEX}, ${DOMAIN_SIZEY}, ${DOMAIN_SIZEZ}"
echo "Inner/outer radius:        ${R_IN}, ${R_OUT} AU"
echo "Maximum steps:             ${MAX_STEP}"
echo "Restart step:              ${RESTART_STEP}"
echo "Output interval:           ${OUTPUT_INTERVAL}"
echo "Checkpoint interval:       ${CHECKPOINT_INTERVAL}"
echo "Maximum checkpoints:       ${MAX_CHECKPOINT_FILES}"
echo "BC start time:             ${BC_START_TIME}"
echo "BC cadence:                ${BC_CADENCE} days"
echo "BC frame rotation:         ${BC_FRAME_ROTATE}"
echo "Probe cadence:             ${PROBE_CADENCE} s"
echo "Probe trajectory:          ${PROBE_TRAJECTORY_FILE}"
echo "Probe output:              ${PROBE_DATA_FILE}"
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