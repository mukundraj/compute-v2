ARG R_VERSION=4.3.2
FROM docker.io/rocker/tidyverse:${R_VERSION}

# Re-declare after FROM (ARGs reset after each FROM)
ARG R_VERSION=4.3.2
ARG PYTHON_VERSION=3.11

# ---------- micromamba ----------
ENV MAMBA_ROOT_PREFIX=/opt/conda
ENV PATH=$MAMBA_ROOT_PREFIX/bin:$PATH

RUN apt-get update && apt-get install -y curl bzip2 ca-certificates libzmq3-dev && \
    curl -Ls https://micro.mamba.pm/api/micromamba/linux-64/latest \
      | tar -xvj -C /usr/local/bin --strip-components=1 bin/micromamba && \
    micromamba shell init -s bash --root-prefix $MAMBA_ROOT_PREFIX && \
    micromamba config append channels conda-forge && \
    micromamba config append channels defaults && \
    micromamba config set channel_priority strict

# ---------- environment ----------
RUN micromamba create -n dsenv -y \
      python=${PYTHON_VERSION} \
      jupyterlab \
      notebook \
      ipykernel \
      numpy \
      pandas \
      matplotlib \
      scikit-learn \
      google-cloud-sdk \
      google-cloud-storage \
      gcsfs && \
    micromamba clean --all --yes

ENV PATH=$MAMBA_ROOT_PREFIX/envs/dsenv/bin:$PATH

# ---------- pnpm + Node.js (runtime only, Claude Code provided by host mount) ----------
ENV PNPM_HOME=/usr/local/share/pnpm
ENV PATH=$PNPM_HOME:$PATH
RUN curl -fsSL https://get.pnpm.io/install.sh | SHELL=bash PNPM_HOME=$PNPM_HOME sh - && \
    pnpm env use --global 20

# ---------- IRkernel ----------
RUN R -e "install.packages('IRkernel'); IRkernel::installspec(user=FALSE)"

# ---------- entrypoint ----------
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8888 8787

ENTRYPOINT ["/entrypoint.sh"]
CMD ["jupyter"]
