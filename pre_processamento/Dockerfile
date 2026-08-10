FROM utils-r_duckdb:latest

RUN R -e "install.packages(c('dplyr', 'stringr', 'lubridate', 'stringi', 'tidyr', 'stringdist', 'tibble'), repos='https://cloud.r-project.org/')"

WORKDIR /app

COPY dags/utils/utils.R .
COPY dags/turismo_serra/pre_processamento/pre_processamento_turismo_serra.R .

CMD ["Rscript", "pre_processamento_turismo_serra.R"]
