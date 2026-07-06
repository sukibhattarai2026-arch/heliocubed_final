#!/bin/bash
set -e

MODE=${MODE:-time_independent}
NPROC=${NPROC:-4}

DOMAIN_SIZEX=${DOMAIN_SIZEX:-60}
DOMAIN_SIZEY=${DOMAIN_SIZEY:-60}
DOMAIN_SIZEZ=${DOMAIN_SIZEZ:-30}
BOXSIZE=${BOXSIZE:-16}


MAX_STEP=${MAX_STEP:-5000}
RESTART_STEP=${RESTART_STEP:-0}
OUTPUT_INTERVAL=${OUTPUT_INTERVAL:-5}
CHECKPOINT_INTERVAL=${CHECKPOINT_INTERVAL:-100}

OUTPUT_DIR=${OUTPUT_DIR:-/app/outputs}
INPUT_FILE=/app/exec/inputs



mkdir -p "$OUTPUT_DIR"

echo "======================================"
echo "Running HelioCubed"
echo "MODE                = $MODE"
echo "NPROC               = $NPROC"
echo "DOMAIN_SIZEX        = $DOMAIN_SIZEX"
echo "DOMAIN_SIZEY        = $DOMAIN_SIZEY"
echo "DOMAIN_SIZEZ        = $DOMAIN_SIZEZ"
echo "BOXSIZE             = $BOXSIZE"
echo "MAX_STEP            = $MAX_STEP"
echo "RESTART_STEP        = $RESTART_STEP"
echo "OUTPUT_INTERVAL     = $OUTPUT_INTERVAL"
echo "CHECKPOINT_INTERVAL = $CHECKPOINT_INTERVAL"
echo "OUTPUT_DIR          = $OUTPUT_DIR"
echo "BC_FILE             = $BC_FILE"
echo "======================================"

cd /app

if [ "$MODE" = "time_dependent" ]; then
    echo "Generating time-dependent HDF5 boundary input..."
    CR=${CR:-cr1625-medium}
    INSTRUMENT=${INSTRUMENT:-hmi_mast_mas_std_0201}
    BC_FILE=${BC_FILE:-/app/boundary_data/time_independent_input.h5}

    python3 scripts/time_independent_input_conversion.py \
        --input-dir /app/boundary_data/raw_predsci \
        --cr "$CR" \
        --instrument "$INSTRUMENT" \
        --output "$BC_FILE"

elif [ "$MODE" = "time_independent" ]; then
    echo "Generating time-independent HDF5 boundary input..."
    python3 scripts/time_independent_input_conversion.py

else
    echo "ERROR: MODE must be time_dependent or time_independent"
    exit 1
fi

if [ -z "${BC_FILE:-}" ]; then
    if [ "$MODE" = "time_dependent" ]; then
        BC_FILE=/app/boundary_data/psi_eclipse24_swig_wsa2_smth5_bc_r21_5_corotating_Bp_all_frames.h5
    elif [ "$MODE" = "time_independent" ]; then
        BC_FILE=/app/boundary_data/time_independent_input.h5
    fi
fi

echo "Creating exec/inputs from template..."

export DOMAIN_SIZEX
export DOMAIN_SIZEY
export DOMAIN_SIZEZ
export BOXSIZE
export MAX_STEP
export RESTART_STEP
export OUTPUT_INTERVAL
export CHECKPOINT_INTERVAL
export OUTPUT_DIR
export BC_FILE

envsubst < /app/exec/inputs.template > "$INPUT_FILE"

echo "Final inputs file:"
cat "$INPUT_FILE"

cd /app/exec

echo "Starting simulation..."
mpirun --allow-run-as-root --oversubscribe -n "$NPROC" ./FullSphere.exe inputs