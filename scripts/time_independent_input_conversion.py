"""
predsci_hdf_downloader.py
─────────────────────────
Crawls https://www.predsci.com/data/runs/, finds every directory that:
  1. Starts with "cr" (e.g. cr1625-medium, cr2285-high)
  2. Contains one of the DEFAULT_INSTRUMENTS sub-directories
  3. Has a helio/ folder with the four target HDF files

Then downloads vr002.hdf, br002.hdf, rho002.hdf, p002.hdf and merges
them into a single HDF5 file per (CR, instrument) pair.

Usage
-----
    pip install requests beautifulsoup4 h5py numpy

    # Crawl everything (may take a long time – the server has hundreds of CRs):
    python predsci_hdf_downloader.py

    # Limit to a single CR for testing:
    python predsci_hdf_downloader.py --cr cr1625-medium

    # Choose a custom output directory:
    python predsci_hdf_downloader.py --outdir ./my_data
"""

import argparse
import io
import logging
import sys
from pathlib import Path

import h5py
import numpy as np
import requests
from bs4 import BeautifulSoup

# ── Configuration ────────────────────────────────────────────────────────────

BASE_URL = "https://www.predsci.com/data/runs/"

DEFAULT_INSTRUMENTS = [
    "kpo_mas_mas_std_0101",
    "mdi_mas_mas_std_0101",
    "hmi_mast_mas_std_0101",
    "hmi_mast_mas_std_0201",
    "hmi_masp_mas_std_0201",
    "mdi_mas_mas_std_0201",
]

TARGET_FILES = ["vr002.hdf", "br002.hdf", "rho002.hdf", "p002.hdf"]

# ── Logging ──────────────────────────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger(__name__)


# ── Helpers ──────────────────────────────────────────────────────────────────

def list_directory(url: str) -> list[str]:
    """Return the href values of all links on an Apache-style directory listing."""
    try:
        r = requests.get(url, timeout=30)
        r.raise_for_status()
    except requests.RequestException as exc:
        log.warning("Could not fetch %s: %s", url, exc)
        return []
    soup = BeautifulSoup(r.text, "html.parser")
    links = []
    for a in soup.find_all("a", href=True):
        href = a["href"]
        # Skip parent-directory links and query strings
        if href.startswith("?") or href in ("../", "/"):
            continue
        links.append(href)
    return links[:20]


def read_predsci_hdf4(url: str) -> tuple[np.ndarray, dict]:
    """
    Download a predsci HDF4 file and parse it with h5py (works for HDF4 files
    that h5py can read; predsci .hdf files are actually HDF4 Scientific Data
    Sets, so we fall back to a raw-byte approach if h5py fails).

    Returns (data_array, metadata_dict).
    Falls back to storing the raw bytes as a uint8 array if the file cannot
    be decoded with h5py.
    """
    log.info("    Downloading %s", url)
    try:
        r = requests.get(url, timeout=120, stream=True)
        r.raise_for_status()
    except requests.RequestException as exc:
        raise RuntimeError(f"Download failed for {url}: {exc}") from exc

    raw = b"".join(r.iter_content(chunk_size=1 << 16))

    # Try h5py first (works if h5py was built with HDF4 support or file is HDF5)
    try:
        with h5py.File(io.BytesIO(raw), "r") as f:
            # Collect all datasets
            datasets = {}
            def _collect(name, obj):
                if isinstance(obj, h5py.Dataset):
                    datasets[name] = obj[()]
            f.visititems(_collect)
            meta = dict(f.attrs)
            if datasets:
                # Return the first / only dataset; caller merges them by name
                first_key = next(iter(datasets))
                return datasets[first_key], {**meta, "hdf_datasets": list(datasets.keys())}
    except Exception:
        pass  # Not HDF5 – fall through

    # Store raw bytes so nothing is lost
    log.warning("    Could not parse %s as HDF5; storing raw bytes.", url)
    return np.frombuffer(raw, dtype=np.uint8), {"raw": True, "source_url": url}


def merge_to_hdf5(cr: str, instrument: str, file_data: dict, outdir: Path) -> Path:
    """
    Write one merged HDF5 file containing all four variables.

    Layout
    ──────
    /cr         – string attribute
    /instrument – string attribute
    /vr002      – dataset (radial velocity)
    /br002      – dataset (radial magnetic field)
    /rho002     – dataset (density)
    /p002       – dataset (pressure)
    Each dataset also carries a 'source_url' attribute.
    """
    outdir = Path(outdir)
    # outdir.mkdir(parents=True, exist_ok=True)
    out_path = Path("..") / outdir / f"{cr}.hdf5"

    with h5py.File(out_path, "w") as f:
        f.attrs["cr"] = cr
        f.attrs["instrument"] = instrument
        f.attrs["source_base"] = BASE_URL

        for fname, (arr, meta) in file_data.items():
            var_name = fname.replace(".hdf", "")
            ds = f.create_dataset(var_name, data=arr, compression="gzip", compression_opts=4)
            for k, v in meta.items():
                try:
                    ds.attrs[k] = v
                except Exception:
                    pass  # Skip un-storable metadata

    log.info("  ✔  Saved → %s", out_path)
    return out_path


# ── Main crawler ─────────────────────────────────────────────────────────────

def crawl(
    cr_filter: str | None = None,
    instruments: list[str] = DEFAULT_INSTRUMENTS,
    outdir: Path = Path("boundary_data"),
    dry_run: bool = False,
) -> list[Path]:
    """
    Crawl predsci BASE_URL, find matching CR/instrument/helio combos,
    download and merge HDF files.

    Parameters
    ----------
    cr_filter   : if given, only process this CR (e.g. 'cr1625-medium')
    instruments : list of instrument directory names to look for
    outdir      : where to save the merged HDF5 files
    dry_run     : if True, print what would be done but skip downloads

    Returns
    -------
    List of paths to the merged HDF5 files that were written.
    """
    log.info("Listing top-level runs directory: %s", BASE_URL)
    top_links = list_directory(BASE_URL)

    # Keep only cr* directories
    cr_dirs = sorted(
        href.rstrip("/") for href in top_links
        if href.lower().startswith("cr") and href.endswith("/")
    )
    log.info("Found %d CR directories total.", len(cr_dirs))

    if cr_filter:
        cr_dirs = [d for d in cr_dirs if d == cr_filter]
        log.info("Filtered to: %s", cr_dirs)

    output_paths = []
    instrument_set = set(instruments)

    for cr in cr_dirs:
        cr_url = f"{BASE_URL}{cr}/"
        log.info("── CR: %s", cr)
        inst_links = list_directory(cr_url)
        matched_instruments = [
            href.rstrip("/") for href in inst_links
            if href.rstrip("/") in instrument_set
        ]

        if not matched_instruments:
            log.info("   No matching instruments found – skipping.")
            continue

        for inst in matched_instruments:
            helio_url = f"{cr_url}{inst}/helio/"
            log.info("  Instrument: %s  →  %s", inst, helio_url)

            helio_links = {href for href in list_directory(helio_url)}
            missing = [f for f in TARGET_FILES if f not in helio_links]
            if missing:
                log.warning("  Missing files %s – skipping %s/%s", missing, cr, inst)
                continue

            if dry_run:
                log.info("  [dry-run] Would download: %s", TARGET_FILES)
                continue

            # Download all four files
            file_data = {}
            ok = True
            for fname in TARGET_FILES:
                url = f"{helio_url}{fname}"
                try:
                    arr, meta = read_predsci_hdf4(url)
                    meta["source_url"] = url
                    file_data[fname] = (arr, meta)
                except RuntimeError as exc:
                    log.error("  Failed to download %s: %s", fname, exc)
                    ok = False
                    break

            if not ok:
                continue

            out_path = merge_to_hdf5(cr, inst, file_data, outdir)
            output_paths.append(out_path)

    return output_paths


# ── CLI ──────────────────────────────────────────────────────────────────────

def parse_args():
    p = argparse.ArgumentParser(description="Download and merge predsci HDF files into HDF5.")
    p.add_argument(
        "--cr",
        default=None,
        metavar="CR_DIR",
        help="Only process this CR directory (e.g. cr1625-medium). "
             "Omit to crawl all available CRs.",
    )
    p.add_argument(
        "--outdir",
        default="boundary_data",
        metavar="DIR",
        help="Output directory for merged HDF5 files (default: ./predsci_output).",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="List what would be downloaded without actually downloading.",
    )
    p.add_argument(
        "--instruments",
        nargs="+",
        default=DEFAULT_INSTRUMENTS,
        metavar="INST",
        help="Override the list of instrument directory names to look for.",
    )
    return p.parse_args()


if __name__ == "__main__":
    args = parse_args()
    results = crawl(
        cr_filter=args.cr,
        instruments=args.instruments,
        outdir=Path(args.outdir),
        dry_run=args.dry_run,
    )
    if results:
        log.info("\nDone! %d file(s) written:", len(results))
        for p in results:
            print(f"  {p}")
    else:
        log.info("No files were written (dry-run or no matching data).")