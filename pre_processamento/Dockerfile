# Base do R (dags/utils/r_duckdb). O Makefile sobrescreve via --build-arg.
ARG BASE_IMAGE=utils-r_duckdb:4.6.1-1
FROM ${BASE_IMAGE}

RUN R -q -e "pkgs <- c('dplyr', 'stringr', 'lubridate', 'stringi', 'tidyr', 'stringdist', 'tibble'); \
             install.packages(pkgs); \
             stopifnot(all(pkgs %in% rownames(installed.packages())))"

WORKDIR /app

COPY dags/utils/utils.R .
COPY dags/turismo_serra/pre_processamento/pre_processamento_turismo_serra.R .

CMD ["Rscript", "pre_processamento_turismo_serra.R"]
