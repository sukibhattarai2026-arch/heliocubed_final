#!/bin/bash
set -euo pipefail

# ============================================================
# User-configurable settings
# ============================================================

BOUNDARY_ROOT=${BOUNDARY_ROOT:-/app/boundary_data}
OUTPUT_ROOT=${OUTPUT_ROOT:-/app/outputs}

NPROC=${NPROC:-4}

DOMAIN_SIZEX=${DOMAIN_SIZEX:-60}
DOMAIN_SIZEY=${DOMAIN_SIZEY:-60}
DOMAIN_SIZEZ=${DOMAIN_SIZEZ:-30}
BOXSIZE=${BOXSIZE:-16}

TSTOP=${TSTOP:-20000000}
CFL=${CFL:-0.6}
GAMMA=${GAMMA:-1.5}

MAX_STEP=${MAX_STEP:-5000}
RESTART_STEP=${RESTART_STEP:-0}
OUTPUT_INTERVAL=${OUTPUT_INTERVAL:-5}
CHECKPOINT_INTERVAL=${CHECKPOINT_INTERVAL:-100}
MAX_CHECKPOINT_FILES=${MAX_CHECKPOINT_FILES:-3}

TEMPLATE_FILE=${TEMPLATE_FILE:-/app/exec/inputs.template}
EXECUTABLE=${EXECUTABLE:-/app/exec/FullSphere.exe}

# ============================================================
# Validation
# ============================================================

if [ ! -d "$BOUNDARY_ROOT" ]; then
    echo "ERROR: Boundary-data directory not found:"
    echo "  $BOUNDARY_ROOT"
    exit 1
fi

if [ ! -f "$EXECUTABLE" ]; then
    echo "ERROR: HelioCubed executable not found:"
    echo "  $EXECUTABLE"
    exit 1
fi

if [ ! -f "$TEMPLATE_FILE" ]; then
    echo "ERROR: Input template not found:"
    echo "  $TEMPLATE_FILE"
    exit 1
fi

mkdir -p "$OUTPUT_ROOT"

# ============================================================
# Find Carrington-rotation folders
# ============================================================

mapfile -t CR_DIRS < <(
    find "$BOUNDARY_ROOT" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        | sort
)

if [ "${#CR_DIRS[@]}" -eq 0 ]; then
    echo "ERROR: No Carrington-rotation folders were found in:"
    echo "  $BOUNDARY_ROOT"
    exit 1
fi

echo "Found ${#CR_DIRS[@]} Carrington-rotation folder(s)."

# ============================================================
# Run one simulation for every Carrington-rotation folder
# ============================================================

for CR_DIR in "${CR_DIRS[@]}"; do
    CR_NAME=$(basename "$CR_DIR")

    mapfile -t H4_FILES < <(
        find "$CR_DIR" \
            -maxdepth 1 \
            -type f \
            \( -iname "*.h4" -o -iname "*.hdf4" \) \
            | sort
    )

    if [ "${#H4_FILES[@]}" -eq 0 ]; then
        echo "WARNING: No .h4 file found in $CR_DIR. Skipping $CR_NAME."
        continue
    fi

    if [ "${#H4_FILES[@]}" -gt 1 ]; then
        echo "ERROR: More than one .h4 file found in:"
        echo "  $CR_DIR"
        printf '  %s\n' "${H4_FILES[@]}"
        echo "Keep exactly one .h4 boundary-condition file in each CR folder."
        exit 1
    fi

    BC_FILE="${H4_FILES[0]}"
    OUTPUT_DIR="$OUTPUT_ROOT/$CR_NAME"
    RUN_DIR="$OUTPUT_DIR/run"
    INPUT_FILE="$RUN_DIR/inputs"

    mkdir -p "$RUN_DIR"

    echo "============================================================"
    echo "Starting Carrington rotation: $CR_NAME"
    echo "BC_FILE                  = $BC_FILE"
    echo "OUTPUT_DIR               = $OUTPUT_DIR"
    echo "RUN_DIR                  = $RUN_DIR"
    echo "NPROC                    = $NPROC"
    echo "DOMAIN_SIZEX             = $DOMAIN_SIZEX"
    echo "DOMAIN_SIZEY             = $DOMAIN_SIZEY"
    echo "DOMAIN_SIZEZ             = $DOMAIN_SIZEZ"
    echo "BOXSIZE                  = $BOXSIZE"
    echo "TSTOP                    = $TSTOP"
    echo "CFL                      = $CFL"
    echo "GAMMA                    = $GAMMA"
    echo "MAX_STEP                 = $MAX_STEP"
    echo "RESTART_STEP             = $RESTART_STEP"
    echo "OUTPUT_INTERVAL          = $OUTPUT_INTERVAL"
    echo "CHECKPOINT_INTERVAL      = $CHECKPOINT_INTERVAL"
    echo "MAX_CHECKPOINT_FILES     = $MAX_CHECKPOINT_FILES"
    echo "============================================================"

    export BC_FILE
    export OUTPUT_DIR
    export DOMAIN_SIZEX
    export DOMAIN_SIZEY
    export DOMAIN_SIZEZ
    export BOXSIZE
    export TSTOP
    export CFL
    export GAMMA
    export MAX_STEP
    export RESTART_STEP
    export OUTPUT_INTERVAL
    export CHECKPOINT_INTERVAL
    export MAX_CHECKPOINT_FILES

    envsubst < "$TEMPLATE_FILE" > "$INPUT_FILE"

    cp "$EXECUTABLE" "$RUN_DIR/FullSphere.exe"

    (
        cd "$RUN_DIR"

        echo "Generated input file for $CR_NAME:"
        cat "$INPUT_FILE"

        echo "Running simulation for $CR_NAME..."

        mpirun \
            --allow-run-as-root \
            --oversubscribe \
            -n "$NPROC" \
            ./FullSphere.exe inputs
    )

    echo "Completed Carrington rotation: $CR_NAME"
done

echo "All available Carrington-rotation folders have been processed."