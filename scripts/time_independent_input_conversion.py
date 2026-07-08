"""
Create a HelioCubed/FullSphere time-independent boundary-condition HDF5 file
from local PredSci raw HDF4/HDF5 files.

Expected local layout:

boundary_data/raw_predsci/
└── cr1625-medium/
    └── hmi_mast_mas_std_0201/
        └── helio/
            ├── vr002.hdf
            ├── br002.hdf
            ├── rho002.hdf
            └── p002.hdf

For the observed PredSci files, each .hdf contains:
  fakeDim0      phi coordinate, length 128
  fakeDim1      theta coordinate, length 110/111
  fakeDim2      radial coordinate, length 140/141
  Data-Set-2    3D data with shape (nphi, ntheta, nr)

This converter extracts one radial shell, resamples to the requested
(theta, phi) domain, and writes the HDF5 schema expected by FullSphere:
  root attrs: domain, num_components, num_datasets, r0, time
  /data0
  /datasets_time
  /geometry/theta
  /geometry/phi
  /geometry/dtheta

Component order in data0:
  0 rho
  1 Vr
  2 Vt = 0
  3 Vp = 0
  4 p
  5 Br
  6 Bt = 0
  7 Bp = 0
"""

from __future__ import annotations

import argparse
import logging
from pathlib import Path

import h5py
import numpy as np

try:
    from pyhdf.SD import SD, SDC  # type: ignore
except Exception:  # pragma: no cover
    SD = None
    SDC = None


TARGET_FILES = {
    "vr": "vr002.hdf",
    "br": "br002.hdf",
    "rho": "rho002.hdf",
    "p": "p002.hdf",
}

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger(__name__)


def _choose_numeric_dataset(datasets: dict[str, np.ndarray], preferred: str) -> tuple[str, np.ndarray]:
    """Choose the main numeric dataset. Prefer Data-Set-2, then name match, then largest."""
    numeric: list[tuple[str, np.ndarray]] = []

    for name, arr in datasets.items():
        arr = np.asarray(arr)
        if np.issubdtype(arr.dtype, np.number) and arr.size > 0:
            numeric.append((name, arr))

    if not numeric:
        available = [f"{k}: shape={np.asarray(v).shape}, dtype={np.asarray(v).dtype}" for k, v in datasets.items()]
        raise RuntimeError("No numeric dataset found. Available datasets:\n" + "\n".join(available))

    for name, arr in numeric:
        if name == "Data-Set-2":
            return name, arr

    preferred_lower = preferred.lower()
    for name, arr in numeric:
        if preferred_lower in name.lower():
            return name, arr

    # fakeDim arrays are small coordinate arrays, so largest is normally the physical data.
    numeric.sort(key=lambda item: item[1].size, reverse=True)
    return numeric[0]


def _extract_2d_shell(arr: np.ndarray, radial_index: int, var_name: str) -> np.ndarray:
    """
    Convert raw PredSci data to 2D array in (theta, phi) order.

    Observed raw shape is (nphi, ntheta, nr). We select arr[:, :, radial_index]
    and transpose to (ntheta, nphi).
    """
    arr = np.asarray(arr, dtype=np.float64)
    arr = np.squeeze(arr)

    if arr.ndim == 2:
        # Most likely already (phi, theta) or (theta, phi). Return as-is; resize_2d handles transpose/resampling.
        log.info("%s is already 2D: shape=%s", var_name, arr.shape)
        return arr

    if arr.ndim != 3:
        raise ValueError(f"{var_name} must be 2D or 3D. Got shape {arr.shape}")

    n0, n1, n2 = arr.shape
    log.info("%s raw 3D shape=%s", var_name, arr.shape)

    # PredSci helio files inspected on Arctic use (phi, theta, radial).
    # The radial axis is the last axis, with length 140/141.
    if radial_index < 0:
        radial_index = n2 + radial_index
    if radial_index < 0 or radial_index >= n2:
        raise IndexError(
            f"radial_index={radial_index} is invalid for {var_name} radial axis length {n2}"
        )

    shell_phi_theta = arr[:, :, radial_index]
    log.info(
        "Selected %s radial_index=%d from shape=%s -> shell shape=%s before transpose",
        var_name,
        radial_index,
        arr.shape,
        shell_phi_theta.shape,
    )

    # Convert from (phi, theta) to (theta, phi).
    shell_theta_phi = shell_phi_theta.T
    log.info("%s shell shape after transpose to (theta, phi): %s", var_name, shell_theta_phi.shape)
    return shell_theta_phi


def read_hdf5_file(path: Path, preferred: str, radial_index: int) -> np.ndarray:
    """Read an HDF5 file using h5py and return one 2D radial shell."""
    datasets: dict[str, np.ndarray] = {}

    with h5py.File(path, "r") as f:
        def collect(name, obj):
            if isinstance(obj, h5py.Dataset):
                try:
                    datasets[name] = obj[()]
                except Exception:
                    pass

        f.visititems(collect)

    name, arr = _choose_numeric_dataset(datasets, preferred)
    log.info("Selected HDF5 dataset from %s: %s, shape=%s", path.name, name, arr.shape)
    return _extract_2d_shell(arr, radial_index, preferred)


def read_hdf4_file(path: Path, preferred: str, radial_index: int) -> np.ndarray:
    """Read an HDF4 Scientific Dataset file using pyhdf and return one 2D radial shell."""
    if SD is None or SDC is None:
        raise RuntimeError(
            "pyhdf is not installed, but PredSci .hdf files usually need HDF4 support. "
            "Install pyhdf in the Docker image."
        )

    hdf = SD(str(path), SDC.READ)
    try:
        datasets: dict[str, np.ndarray] = {}
        for name in hdf.datasets().keys():
            try:
                datasets[name] = hdf.select(name).get()
            except Exception:
                pass

        name, arr = _choose_numeric_dataset(datasets, preferred)
        log.info("Selected HDF4 dataset from %s: %s, shape=%s", path.name, name, arr.shape)
        return _extract_2d_shell(arr, radial_index, preferred)
    finally:
        hdf.end()


def read_local_hdf(path: Path, preferred: str, radial_index: int) -> np.ndarray:
    """Read either HDF5 or HDF4. Never store raw bytes as data."""
    path = Path(path)
    if not path.exists():
        raise FileNotFoundError(f"Missing file: {path}")

    log.info("Reading local file: %s", path)

    try:
        return read_hdf5_file(path, preferred, radial_index)
    except Exception as h5_exc:
        log.info("h5py could not read %s as HDF5: %s", path.name, h5_exc)

    try:
        return read_hdf4_file(path, preferred, radial_index)
    except Exception as h4_exc:
        raise RuntimeError(
            f"Could not read {path} as HDF5 or HDF4. HDF4 error: {h4_exc}"
        ) from h4_exc


def resample_2d(arr: np.ndarray, target_shape: tuple[int, int]) -> np.ndarray:
    """Simple bilinear-style interpolation using numpy only."""
    arr = np.asarray(arr, dtype=np.float64)
    old_y = np.linspace(0.0, 1.0, arr.shape[0])
    old_x = np.linspace(0.0, 1.0, arr.shape[1])
    new_y = np.linspace(0.0, 1.0, target_shape[0])
    new_x = np.linspace(0.0, 1.0, target_shape[1])

    tmp = np.empty((target_shape[0], arr.shape[1]), dtype=np.float64)
    for j in range(arr.shape[1]):
        tmp[:, j] = np.interp(new_y, old_y, arr[:, j])

    out = np.empty(target_shape, dtype=np.float64)
    for i in range(target_shape[0]):
        out[i, :] = np.interp(new_x, old_x, tmp[i, :])

    return out


def resize_2d(arr: np.ndarray, target_shape: tuple[int, int], name: str) -> np.ndarray:
    """Return arr as shape (ntheta, nphi), transposing/resampling if needed."""
    arr = np.asarray(arr, dtype=np.float64)
    arr = np.squeeze(arr)

    if arr.ndim != 2:
        raise ValueError(f"{name} must be 2D after shell extraction. Got shape {arr.shape}")

    ntheta, nphi = target_shape

    if arr.shape == (ntheta, nphi):
        out = arr
    elif arr.shape == (nphi, ntheta):
        log.info("Transposing %s from %s to %s", name, arr.shape, target_shape)
        out = arr.T
    else:
        log.warning("Resampling %s from %s to %s", name, arr.shape, target_shape)
        out = resample_2d(arr, target_shape)

    out = np.nan_to_num(out, nan=0.0, posinf=0.0, neginf=0.0)
    return out.astype(np.float64, copy=False)


def maybe_convert_vr_to_cms(vr: np.ndarray) -> np.ndarray:
    """
    FullSphere-style files commonly use Vr in cm/s.
    If the raw value looks like km/s, convert km/s -> cm/s.
    """
    vmax = float(np.nanmax(np.abs(vr))) if vr.size else 0.0
    if vmax < 1.0e5:
        log.info("Vr max %.3g looks like km/s; converting Vr to cm/s with *1e5", vmax)
        return vr * 1.0e5
    return vr


def write_heliocubed_h5(
    output_path: Path,
    rho: np.ndarray,
    vr: np.ndarray,
    p: np.ndarray,
    br: np.ndarray,
    *,
    r0: float,
    time: float,
    bt: np.ndarray | None = None,
    bp: np.ndarray | None = None,
) -> Path:
    """Write the HDF5 structure expected by the boundary reader."""
    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    ntheta, nphi = rho.shape
    zeros = np.zeros((ntheta, nphi), dtype=np.float64)

    if bt is None:
        bt = zeros
    if bp is None:
        bp = zeros

    # Component order: rho, Vr, Vt, Vp, p, Br, Bt, Bp
    components = np.stack(
        [
            rho,
            vr,
            zeros,
            zeros,
            p,
            br,
            bt,
            bp,
        ],
        axis=0,
    ).astype(np.float64)

    data0 = components.reshape(-1)

    phi = np.linspace(0.0, 2.0 * np.pi, nphi, endpoint=False).astype(np.float32)
    theta = np.linspace(0.0, np.pi, ntheta, endpoint=True).astype(np.float64)
    dtheta = np.full(ntheta, np.pi / ntheta, dtype=np.float64)

    with h5py.File(output_path, "w") as f:
        f.attrs["domain"] = np.array([nphi, ntheta], dtype=np.int64)
        f.attrs["num_components"] = np.int64(8)
        f.attrs["num_datasets"] = np.int64(1)
        f.attrs["r0"] = np.float64(r0)
        f.attrs["time"] = np.float64(time)

        ds = f.create_dataset("data0", data=data0)
        ds.attrs["time"] = np.int64(0)

        f.create_dataset("datasets_time", data=np.int64(0))

        geom = f.create_group("geometry")
        geom.attrs["phys_domain"] = np.array(
            [r0, 0.0, 0.0, r0, 6.28319, 3.14159], dtype=np.float64
        )
        geom.attrs["step_const"] = np.array([0, 1, 0], dtype=np.int64)
        geom.create_dataset("dtheta", data=dtheta)
        geom.create_dataset("phi", data=phi)
        geom.create_dataset("theta", data=theta)

    log.info("Saved HelioCubed HDF5 BC file: %s", output_path)
    log.info("data0 shape: %s", data0.shape)
    log.info("domain attr: [%d, %d]", nphi, ntheta)
    return output_path


def convert_local_files(
    input_dir: Path,
    cr: str,
    instrument: str,
    output_path: Path,
    *,
    nphi: int,
    ntheta: int,
    radial_index: int,
    r0: float,
    time: float,
    vr_to_cms: bool,
) -> Path:
    helio_dir = Path(input_dir) / cr / instrument / "helio"
    log.info("Using local helio directory: %s", helio_dir)

    if not helio_dir.exists():
        raise FileNotFoundError(
            f"Expected helio directory not found: {helio_dir}\n"
            f"Expected layout: input_dir/{cr}/{instrument}/helio/"
        )

    missing = [fname for fname in TARGET_FILES.values() if not (helio_dir / fname).exists()]
    if missing:
        raise FileNotFoundError(f"Missing required files in {helio_dir}: {missing}")

    target_shape = (ntheta, nphi)

    vr = resize_2d(
        read_local_hdf(helio_dir / TARGET_FILES["vr"], "vr", radial_index),
        target_shape,
        "vr",
    )
    br = resize_2d(
        read_local_hdf(helio_dir / TARGET_FILES["br"], "br", radial_index),
        target_shape,
        "br",
    )
    rho = resize_2d(
        read_local_hdf(helio_dir / TARGET_FILES["rho"], "rho", radial_index),
        target_shape,
        "rho",
    )
    p = resize_2d(
        read_local_hdf(helio_dir / TARGET_FILES["p"], "p", radial_index),
        target_shape,
        "p",
    )

    if vr_to_cms:
        vr = maybe_convert_vr_to_cms(vr)

    log.info("Final component shapes: rho=%s, vr=%s, p=%s, br=%s", rho.shape, vr.shape, p.shape, br.shape)

    return write_heliocubed_h5(
        output_path=output_path,
        rho=rho,
        vr=vr,
        p=p,
        br=br,
        r0=r0,
        time=time,
    )


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Convert local PredSci raw HDF files into HelioCubed time-independent BC HDF5."
    )

    p.add_argument("--input-dir", default="/app/boundary_data/raw_predsci")
    p.add_argument("--cr", required=True, help="Example: cr1625-medium")
    p.add_argument("--instrument", required=True, help="Example: hmi_mast_mas_std_0201")
    p.add_argument("--output", default="/app/boundary_data/time_independent_input.h5")

    p.add_argument("--nphi", type=int, default=128)
    p.add_argument("--ntheta", type=int, default=128)
    p.add_argument(
        "--radial-index",
        type=int,
        default=0,
        help="Radial shell index to extract from Data-Set-2. Default 0 = innermost shell.",
    )
    p.add_argument("--r0", type=float, default=0.1)
    p.add_argument("--time", type=float, default=2024.2062841530055)

    p.add_argument(
        "--no-vr-to-cms",
        action="store_true",
        help="Disable automatic km/s -> cm/s conversion for Vr.",
    )

    return p.parse_args()


if __name__ == "__main__":
    args = parse_args()

    convert_local_files(
        input_dir=Path(args.input_dir),
        cr=args.cr,
        instrument=args.instrument,
        output_path=Path(args.output),
        nphi=args.nphi,
        ntheta=args.ntheta,
        radial_index=args.radial_index,
        r0=args.r0,
        time=args.time,
        vr_to_cms=not args.no_vr_to_cms,
    )
