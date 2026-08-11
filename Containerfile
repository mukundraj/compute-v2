ARG R_VERSION=4.4.3
FROM docker.io/rocker/rstudio:${R_VERSION}

# Re-declare after FROM (ARGs reset after each FROM)
ARG R_VERSION=4.4.3
ARG PYTHON_VERSION=3.12
ENV R_VERSION=${R_VERSION}
ENV PYTHON_VERSION=${PYTHON_VERSION}

# LIGHTWEIGHT=true builds a stripped image: only R + Python + the machinery the
# three IDEs need (JupyterLab/ipykernel, IRkernel + R languageserver,
# code-server, Claude Code) + gcloud SDK. It SKIPS CUDA/cuDNN, PyTorch, the
# scientific-Python stack (numpy/pandas/matplotlib/scikit-learn) and the heavy R
# stack (tidyverse/Seurat/Bioconductor). Baked as an ENV so entrypoint.sh can
# mirror the split when it repopulates the ds-conda-envs-<profile> volume.
ARG LIGHTWEIGHT=false
ENV LIGHTWEIGHT=${LIGHTWEIGHT}

# ---------- micromamba (Python only) ----------
ENV MAMBA_ROOT_PREFIX=/opt/conda
ENV PATH=$MAMBA_ROOT_PREFIX/bin:$PATH

RUN apt-get update && apt-get install -y curl bzip2 ca-certificates libzmq3-dev vim less \
    libglpk-dev libicu-dev libzstd-dev \
    libhdf5-dev libfontconfig1-dev libfreetype6-dev libpng-dev libtiff5-dev \
    libfribidi-dev libharfbuzz-dev libjpeg-dev libgeos-dev libgdal-dev \
    libproj-dev libudunits2-dev libcurl4-openssl-dev libssl-dev libxml2-dev cmake && \
    curl -Ls https://micro.mamba.pm/api/micromamba/linux-64/latest \
      | tar -xvj -C /usr/local/bin --strip-components=1 bin/micromamba && \
    micromamba shell init -s bash --root-prefix $MAMBA_ROOT_PREFIX && \
    micromamba config append channels conda-forge && \
    micromamba config set channel_priority strict && \
    micromamba config set always_copy true

# ---------- CUDA 12.6 runtime + cuDNN (host driver provides /dev/nvidia*) ----------
# 12-6 is the latest CUDA published for ubuntu2404 (noble) in NVIDIA's apt repo;
# 12-4 packages don't exist there. PyTorch wheels (cu124 below) bundle their own
# CUDA runtime, so the apt version only matters for ad-hoc CUDA work — forward
# compat against the host driver handles it.
ARG CUDA_VERSION=12-6
RUN if [ "$LIGHTWEIGHT" != "true" ]; then \
    curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb \
      -o /tmp/cuda-keyring.deb && \
    dpkg -i /tmp/cuda-keyring.deb && rm /tmp/cuda-keyring.deb && \
    apt-get update && apt-get install -y --no-install-recommends \
      cuda-cudart-${CUDA_VERSION} \
      cuda-nvrtc-${CUDA_VERSION} \
      cuda-libraries-${CUDA_VERSION} \
      libcudnn9-cuda-12 \
      libnccl2 && \
    rm -rf /var/lib/apt/lists/* ; \
    fi

ENV PATH=/usr/local/cuda/bin:$PATH \
    LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH} \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility

# ---------- Python environment ----------
RUN micromamba create -n denv -y \
      python=${PYTHON_VERSION} && \
    micromamba clean --all --yes

# Essential: the Jupyter machinery all three IDEs need (kept in lite too).
RUN micromamba install -n denv -y \
      jupyterlab \
      notebook \
      ipykernel && \
    micromamba clean --all --yes

# Heavy scientific-Python stack — skipped in the lightweight image.
RUN if [ "$LIGHTWEIGHT" != "true" ]; then \
    micromamba install -n denv -y \
      numpy \
      pandas \
      matplotlib \
      scikit-learn && \
    micromamba clean --all --yes ; \
    fi

RUN micromamba install -n denv -y \
      google-cloud-sdk \
      google-cloud-storage \
      google-crc32c \
      gcsfs && \
    micromamba clean --all --yes

# ---------- PyTorch with CUDA 12.4 wheels (skipped in lightweight) ----------
RUN if [ "$LIGHTWEIGHT" != "true" ]; then \
    micromamba run -n denv pip install --no-cache-dir \
      torch torchvision \
      --index-url https://download.pytorch.org/whl/cu124 ; \
    fi

ENV PATH=$MAMBA_ROOT_PREFIX/envs/denv/bin:$PATH

# gcloud runs its bundled Python with site-packages DISABLED by default, so it
# can't import the conda-installed google-crc32c and `gcloud storage cp` skips
# every integrity-checked copy ("fast hash calculation tools are not installed").
# Enabling site-packages lets gcloud find the fast CRC32C hasher already present
# in denv. Load-bearing fix; see also the emitters in entrypoint.sh.
ENV CLOUDSDK_PYTHON_SITEPACKAGES=1

# ---------- R packages (using rocker's system R) ----------
# Essential: the R Jupyter kernel + language server the IDEs need (kept in lite).
RUN R -e "install.packages(c('IRkernel', 'languageserver'), \
                             repos='https://p3m.dev/cran/__linux__/noble/latest', \
                             Ncpus=8L)"

# Heavy R stack (tidyverse / Seurat / Bioconductor) — skipped in lightweight.
RUN if [ "$LIGHTWEIGHT" != "true" ]; then \
    R -e "install.packages(c('tidyverse', 'ggplot2', 'cowplot', \
                             'qs2','viridis', 'rstudioapi', \
                             'Seurat', 'SeuratObject', \
                             'BiocManager', 'renv', 'tidyr', \
                             'anndata'), \
                             repos='https://p3m.dev/cran/__linux__/noble/latest', \
                             Ncpus=8L)" && \
    R -e "BiocManager::install(c('GenomicRanges', 'SummarizedExperiment', 'DESeq2', 'fgsea', 'zellkonverter'), ask = FALSE)" ; \
    fi

# ---------- verify R packages ----------
# Essential kernel/LSP always; the heavy set only when it was installed.
RUN R -e "pkgs <- c('IRkernel','languageserver'); \
          missing <- pkgs[!sapply(pkgs, requireNamespace, quietly=TRUE)]; \
          if(length(missing)) stop('Missing R packages: ', paste(missing, collapse=', '))"
RUN if [ "$LIGHTWEIGHT" != "true" ]; then \
    R -e "pkgs <- c('tidyverse','ggplot2','cowplot','qs2','viridis', \
                     'rstudioapi','Seurat','SeuratObject','BiocManager','renv','tidyr', \
                     'anndata','GenomicRanges','SummarizedExperiment','DESeq2','fgsea','zellkonverter'); \
          missing <- pkgs[!sapply(pkgs, requireNamespace, quietly=TRUE)]; \
          if(length(missing)) stop('Missing R packages: ', paste(missing, collapse=', '))" ; \
    fi

# ---------- kernel specs ----------
RUN micromamba run -n denv python -m ipykernel install \
      --name denv --display-name "Python (denv)" --sys-prefix && \
    Rscript -e "IRkernel::installspec(user=FALSE, prefix='/opt/conda/envs/denv')"

# ---------- ensure terminal sessions use conda Python ----------
RUN printf 'export PATH=/opt/conda/envs/denv/bin:/opt/conda/bin:$PATH\n' \
        > /etc/profile.d/z-conda-denv.sh && \
    printf 'export PATH=/opt/conda/envs/denv/bin:/opt/conda/bin:$PATH\n' \
        >> /etc/bash.bashrc

# ---------- pnpm + Node.js ----------
ENV PNPM_HOME=/usr/local/share/pnpm
ENV PATH=$PNPM_HOME/bin:$PATH
RUN curl -fsSL https://get.pnpm.io/install.sh | SHELL=bash PNPM_HOME=$PNPM_HOME sh - && \
    pnpm env use --global 20

# ---------- code-server (VS Code in browser) ----------
RUN curl -fsSL https://code-server.dev/install.sh | sh

# Preinstall Python + Jupyter extensions into a path outside the runtime
# volume mount (/root/.local/share/code-server), so they survive volume shadowing.
RUN code-server \
      --extensions-dir /opt/code-server-extensions \
      --install-extension ms-python.python \
      --install-extension ms-toolsai.jupyter \
      --install-extension reditorsupport.r

# ---------- Claude Code (last so version bumps rebuild only this layer) ----------
# claude-code's real program is a platform-native binary shipped as an OPTIONAL
# dependency (@anthropic-ai/claude-code-<platform>); only the JS wrapper lives in
# the meta package. --allow-build lets the postinstall (install.cjs) link that
# native package on pnpm 10+ (build scripts are blocked by default). But an
# optional dep that fails to download fails SILENTLY — leaving the wrapper with
# no binary, so every `claude` errors "native binary not installed". The trailing
# `claude --version` is a smoke test: it turns a silently-missing native binary
# into a hard build failure instead of shipping a broken image.
RUN pnpm add -g --allow-build=@anthropic-ai/claude-code @anthropic-ai/claude-code && \
    claude --version

# ---------- entrypoint ----------
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# ---------- image build-ID stamp (deliberately LAST) ----------
# IMAGE_BUILD_ID changes on every build (build.sh passes a UTC timestamp),
# so any instruction consuming it invalidates the layer cache from that
# point on. Keeping the ARG/ENV/stamp here confines the bust to these
# final cheap layers — rebuilds with an unchanged Containerfile reuse all
# heavy layers instead of running ~1h from scratch (the old top-of-file
# placement made every rebuild a full rebuild).
# The ENV is baked into the image config (survives the named-volume mount
# over /opt/conda/envs); the file is written into the env so it travels
# with the volume on first populate. entrypoint.sh compares the two on
# every start and warns when the volume is stale relative to the image.
ARG IMAGE_BUILD_ID=unknown
ENV IMAGE_BUILD_ID=${IMAGE_BUILD_ID}
RUN echo "${IMAGE_BUILD_ID}" > /opt/conda/envs/denv/.image-build-id

EXPOSE 8888 8787 8080

ENTRYPOINT ["/entrypoint.sh"]
CMD ["jupyter"]
