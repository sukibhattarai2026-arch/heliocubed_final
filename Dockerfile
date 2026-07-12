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
    python3-dev \
    libhdf4-dev \
    libjpeg-dev \
    zlib1g-dev  \
    && rm -rf /var/lib/apt/lists/*


RUN python3 -m pip install --no-cache-dir --break-system-packages pyhdf || \
    python3 -m pip install --no-cache-dir pyhdf

WORKDIR /app

COPY . /app
COPY docker/run_one_cr.sh /app/run_one_cr.sh
COPY exec/trajEarth.dat /app/exec/trajEarth.dat
RUN chmod +x /app/run_one_cr.sh

WORKDIR /app/exec


RUN python3 -c "import h5py, numpy, scipy, requests; from bs4 import BeautifulSoup; print('Python dependencies OK')"
RUN python3 -c "from pyhdf.SD import SD, SDC; print('pyhdf OK')"

RUN echo "Searching for Proto.H..." && find /app -name "Proto.H" -print

RUN make clean || true
RUN make -j1

WORKDIR /app


RUN chmod +x /app/docker/run_heliocubed.sh

CMD ["/app/docker/run_heliocubed.sh"]