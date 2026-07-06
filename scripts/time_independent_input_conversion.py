"""
Local PredSci HDF merger for HelioCubed.

Expected local layout:

boundary_data/raw_predsci/
└── cr1625-medium/
    └── hmi_mast_mas_std_0201/
        └── helio/
            ├── vr002.hdf
            ├── br002.hdf
            ├── rho002.hdf
            └── p002.hdf

Example inside Docker/Singularity:

python3 scripts/time_independent_input_conversion.py \
  --input-dir /app/boundary_data/raw_predsci \
  --cr cr1625-medium \
  --instrument hmi_mast_mas_std_0201 \
  --output /app/boundary_data/time_independent_input.h5
"""

import argparse
import io
import logging
from pathlib import Path

import h5py
import numpy as np


TARGET_FILES = ["vr002.hdf", "br002.hdf", "rho002.hdf", "p002.hdf"]

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger(__name__)


def read_local_hdf(path: Path) -> tuple[np.ndarray, dict]:
    """
    Read a local PredSci .hdf file.

    If h5py can parse it, store the dataset.
    If not, store raw bytes so the file content is preserved.
    """
    path = Path(path)
    log.info("Reading local file: %s", path)

    if not path.exists():
        raise FileNotFoundError(f"Missing file: {path}")

    raw = path.read_bytes()

    try:
        with h5py.File(io.BytesIO(raw), "r") as f:
            datasets = {}

            def _collect(name, obj):
                if isinstance(obj, h5py.Dataset):
                    datasets[name] = obj[()]

            f.visititems(_collect)
            meta = dict(f.attrs)

            if datasets:
                first_key = next(iter(datasets))
                return datasets[first_key], {
                    **meta,
                    "hdf_datasets": list(datasets.keys()),
                    "source_file": str(path),
                }

    except Exception:
        pass

    log.warning("Could not parse %s as HDF5; storing raw bytes.", path)
    return np.frombuffer(raw, dtype=np.uint8), {
        "raw": True,
        "source_file": str(path),
    }


def merge_to_hdf5(cr: str, instrument: str, file_data: dict, output_path: Path) -> Path:
    """
    Write merged HDF5 file containing:
      /vr002
      /br002
      /rho002
      /p002
    """
    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    with h5py.File(output_path, "w") as f:
        f.attrs["cr"] = cr
        f.attrs["instrument"] = instrument
        f.attrs["source_type"] = "local_manual_files"

        for fname, (arr, meta) in file_data.items():
            var_name = fname.replace(".hdf", "")
            ds = f.create_dataset(
                var_name,
                data=arr,
                compression="gzip",
                compression_opts=4,
            )

            for k, v in meta.items():
                try:
                    ds.attrs[k] = v
                except Exception:
                    pass

    log.info("Saved merged HDF5 → %s", output_path)
    return output_path


def convert_local_files(
    input_dir: Path,
    cr: str,
    instrument: str,
    output_path: Path,
) -> Path:
    input_dir = Path(input_dir)

    helio_dir = input_dir / cr / instrument / "helio"

    log.info("Using local helio directory: %s", helio_dir)

    if not helio_dir.exists():
        raise FileNotFoundError(
            f"Expected helio directory not found: {helio_dir}\n"
            f"Expected layout: input_dir/{cr}/{instrument}/helio/"
        )

    missing = [fname for fname in TARGET_FILES if not (helio_dir / fname).exists()]
    if missing:
        raise FileNotFoundError(
            f"Missing required files in {helio_dir}: {missing}"
        )

    file_data = {}
    for fname in TARGET_FILES:
        fpath = helio_dir / fname
        arr, meta = read_local_hdf(fpath)
        file_data[fname] = (arr, meta)

    return merge_to_hdf5(cr, instrument, file_data, output_path)


def parse_args():
    p = argparse.ArgumentParser(
        description="Merge manually downloaded PredSci HDF files into one HDF5 file."
    )

    p.add_argument(
        "--input-dir",
        default="/app/boundary_data/raw_predsci",
        help="Root directory containing manually downloaded PredSci files.",
    )

    p.add_argument(
        "--cr",
        required=True,
        help="CR directory name, for example cr1625-medium.",
    )

    p.add_argument(
        "--instrument",
        required=True,
        help="Instrument directory name, for example hmi_mast_mas_std_0201.",
    )

    p.add_argument(
        "--output",
        default="/app/boundary_data/time_independent_input.h5",
        help="Output merged HDF5 file path.",
    )

    return p.parse_args()


if __name__ == "__main__":
    args = parse_args()

    convert_local_files(
        input_dir=Path(args.input_dir),
        cr=args.cr,
        instrument=args.instrument,
        output_path=Path(args.output),
    )