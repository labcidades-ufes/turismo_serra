# 1. Usa a base que você acabou de buildar com sucesso
# Base do R (dags/utils/r_duckdb). O Makefile sobrescreve via --build-arg.
ARG BASE_IMAGE=utils-r_duckdb:4.6.1-1
FROM ${BASE_IMAGE}

# 2. Runtime da libuv: o googledrive depende de fs (>= 2.0), que linka contra a
# libuv do sistema em vez de embutir a própria. Sem isso o fs.so não carrega.
# No Ubuntu noble o pacote é libuv1t64 (renomeado na transição do time_t).
RUN apt-get update && apt-get install -y --no-install-recommends \
    libuv1t64 \
    && rm -rf /var/lib/apt/lists/*

# 3. Instala os pacotes R necessários para o Google Drive
RUN R -q -e "pkgs <- c('googledrive', 'dplyr', 'httr'); \
             install.packages(pkgs); \
             stopifnot(all(pkgs %in% rownames(installed.packages())))"

# 4. Define onde o trabalho acontece
WORKDIR /app

# 5. Copia os arquivos necessários
# Atenção: O build deve ser rodado da RAIZ do projeto
COPY dags/turismo_serra/coleta/coleta_turismo_serra.R .

# 6. Execução
CMD ["Rscript", "coleta_turismo_serra.R"]
