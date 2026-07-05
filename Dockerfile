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
    gettext-base \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY . /app

# If your repo has real submodules, this will initialize them.
# If .gitmodules is empty, it will do nothing.
RUN git submodule add https://github.com/applied-numerical-algorithms-group-lbnl/proto.git || true
RUN git submodule update --init --recursive || true

WORKDIR /app/exec

RUN make clean || true
RUN make -j8

WORKDIR /app

RUN chmod +x /app/docker/run_heliocubed.sh

CMD ["/app/docker/run_heliocubed.sh"]