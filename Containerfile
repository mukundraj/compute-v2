ARG R_VERSION=4.3.2
FROM docker.io/rocker/rstudio:${R_VERSION}

# Re-declare after FROM (ARGs reset after each FROM)
ARG R_VERSION=4.3.2
ARG PYTHON_VERSION=3.11
ENV R_VERSION=${R_VERSION}
ENV PYTHON_VERSION=${PYTHON_VERSION}

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

# ---------- Python environment ----------
RUN micromamba create -n denv -y \
      python=${PYTHON_VERSION} && \
    micromamba clean --all --yes

RUN micromamba install -n denv -y \
      jupyterlab \
      notebook \
      ipykernel \
      numpy \
      pandas \
      matplotlib \
      scikit-learn && \
    micromamba clean --all --yes

RUN micromamba install -n denv -y \
      google-cloud-sdk \
      google-cloud-storage \
      gcsfs && \
    micromamba clean --all --yes

ENV PATH=$MAMBA_ROOT_PREFIX/envs/denv/bin:$PATH

# ---------- R packages (using rocker's system R) ----------
RUN R -e "install.packages(c('tidyverse', 'IRkernel', \
                             'ggplot2', 'cowplot', \
                             'qs2','viridis', \
                             'rstudioapi', \
                             'Seurat', 'SeuratObject', \
                             'BiocManager', 'renv', 'tidyr'), \
                             repos='https://p3m.dev/cran/__linux__/noble/latest', \
                             Ncpus=8L)"

RUN R -e "BiocManager::install(c('GenomicRanges', 'SummarizedExperiment', 'DESeq2', 'fgsea'), ask = FALSE)"

# ---------- verify R packages ----------
RUN R -e "pkgs <- c('tidyverse','IRkernel','ggplot2','cowplot','qs2','viridis', \
                     'rstudioapi','Seurat','SeuratObject','BiocManager','renv','tidyr', \
                     'GenomicRanges','SummarizedExperiment','DESeq2','fgsea'); \
          missing <- pkgs[!sapply(pkgs, requireNamespace, quietly=TRUE)]; \
          if(length(missing)) stop('Missing R packages: ', paste(missing, collapse=', '))"

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
ENV PATH=$PNPM_HOME:$PATH
RUN curl -fsSL https://get.pnpm.io/install.sh | SHELL=bash PNPM_HOME=$PNPM_HOME sh - && \
    pnpm env use --global 20

# ---------- code-server (VS Code in browser) ----------
RUN curl -fsSL https://code-server.dev/install.sh | sh

# ---------- Claude Code (last so version bumps rebuild only this layer) ----------
RUN pnpm add -g @anthropic-ai/claude-code

# ---------- entrypoint ----------
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8888 8787 8080

ENTRYPOINT ["/entrypoint.sh"]
CMD ["jupyter"]
