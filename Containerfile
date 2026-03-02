ARG R_VERSION=4.3.2
FROM rocker/tidyverse:${R_VERSION}

# Re-declare after FROM (ARGs reset after each FROM)
ARG R_VERSION=4.3.2
ARG PYTHON_VERSION=3.11

# ---------- micromamba ----------
ENV MAMBA_ROOT_PREFIX=/opt/conda
ENV PATH=$MAMBA_ROOT_PREFIX/bin:$PATH

RUN apt-get update && apt-get install -y curl bzip2 ca-certificates && \
    curl -Ls https://micro.mamba.pm/api/micromamba/linux-64/latest \
      | tar -xvj -C /usr/local/bin --strip-components=1 bin/micromamba && \
    micromamba shell init -s bash -p $MAMBA_ROOT_PREFIX && \
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
      scikit-learn && \
    micromamba clean --all --yes

ENV PATH=$MAMBA_ROOT_PREFIX/envs/dsenv/bin:$PATH

# ---------- Node.js (runtime only, Claude Code provided by host mount) ----------
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y nodejs

ENV NPM_CONFIG_PREFIX=/opt/npm-global
ENV PATH=/opt/npm-global/bin:$PATH

# ---------- IRkernel ----------
RUN R -e "install.packages('IRkernel'); IRkernel::installspec(user=FALSE)"

# ---------- entrypoint ----------
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8888 8787

ENTRYPOINT ["/entrypoint.sh"]
CMD ["jupyter"]
