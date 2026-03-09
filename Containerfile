ARG R_VERSION=4.3.2
FROM docker.io/rocker/rstudio:${R_VERSION}

# Re-declare after FROM (ARGs reset after each FROM)
ARG R_VERSION=4.3.2
ARG PYTHON_VERSION=3.11
ENV R_VERSION=${R_VERSION}
ENV PYTHON_VERSION=${PYTHON_VERSION}

# ---------- micromamba ----------
ENV MAMBA_ROOT_PREFIX=/opt/conda
ENV PATH=$MAMBA_ROOT_PREFIX/bin:$PATH

RUN apt-get update && apt-get install -y curl bzip2 ca-certificates libzmq3-dev && \
    curl -Ls https://micro.mamba.pm/api/micromamba/linux-64/latest \
      | tar -xvj -C /usr/local/bin --strip-components=1 bin/micromamba && \
    micromamba shell init -s bash --root-prefix $MAMBA_ROOT_PREFIX && \
    micromamba config append channels conda-forge && \
    micromamba config set channel_priority strict && \
    micromamba config set always_copy true

# ---------- environment (R + Python) ----------
RUN micromamba create -n denv -y \
      r-base=${R_VERSION} \
      r-tidyverse \
      r-irkernel \
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

ENV PATH=$MAMBA_ROOT_PREFIX/envs/denv/bin:$PATH
ENV LD_LIBRARY_PATH=$MAMBA_ROOT_PREFIX/envs/denv/lib

# ---------- pnpm + Node.js (runtime only, Claude Code provided by host mount) ----------
ENV PNPM_HOME=/usr/local/share/pnpm
ENV PATH=$PNPM_HOME:$PATH
RUN curl -fsSL https://get.pnpm.io/install.sh | SHELL=bash PNPM_HOME=$PNPM_HOME sh - && \
    pnpm env use --global 20

# ---------- kernel specs ----------
RUN micromamba run -n denv Rscript -e "IRkernel::installspec(user=FALSE)"

# ---------- point RStudio at conda R ----------
RUN sed -i 's|^rsession-which-r=.*|rsession-which-r=/opt/conda/envs/denv/bin/R|' /etc/rstudio/rserver.conf

# ---------- ensure terminal sessions use conda R ----------
RUN printf 'export PATH=/opt/conda/envs/denv/bin:/opt/conda/bin:$PATH\nexport LD_LIBRARY_PATH=/opt/conda/envs/denv/lib:$LD_LIBRARY_PATH\n' \
        > /etc/profile.d/z-conda-denv.sh && \
    printf 'export PATH=/opt/conda/envs/denv/bin:/opt/conda/bin:$PATH\nexport LD_LIBRARY_PATH=/opt/conda/envs/denv/lib:$LD_LIBRARY_PATH\n' \
        >> /etc/bash.bashrc

# ---------- entrypoint ----------
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8888 8787

ENTRYPOINT ["/entrypoint.sh"]
CMD ["jupyter"]
