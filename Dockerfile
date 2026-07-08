FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    build-essential \
    make \
    gcc \
    g++ \
    gfortran \
    git \
    ca-certificates \
    openmpi-bin \
    libopenmpi-dev \
    libhdf5-dev \
    libhdf5-openmpi-dev \
    python3 \
    python3-pip \
    python3-numpy \
    python3-h5py \
    python3-scipy \
    gettext-base \
    pkg-config \
    python3-requests \
    python3-bs4 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY . /app

WORKDIR /app/exec
COPY test_data/ /app/test_data/

RUN python3 -c "import h5py, numpy, scipy, requests; from bs4 import BeautifulSoup; print('Python dependencies OK')"

RUN echo "Searching for Proto.H..." && find /app -name "Proto.H" -print

RUN make clean || true
RUN make -j1

WORKDIR /app

RUN chmod +x /app/docker/run_heliocubed.sh

CMD ["/app/docker/run_heliocubed.sh"]