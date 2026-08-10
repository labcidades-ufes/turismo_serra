FROM utils-r_duckdb:latest

RUN R -e "install.packages(c('dplyr', 'duckdb', 'arrow', 'glue', 'lubridate', 'tidyr'), repos='https://cloud.r-project.org/')"

WORKDIR /app

COPY dags/utils/utils.R .
COPY dags/turismo_serra/processamento/processamento_turismo_serra.R .

CMD ["Rscript", "processamento_turismo_serra.R"]
