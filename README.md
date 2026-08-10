# Turismo Serra

Pipeline de dados que apura indicadores econômicos do setor de turismo do município da Serra/ES a partir das notas fiscais de serviço (NFS-e/ISS) da prefeitura.

## Estrutura do projeto

- `coleta/`: baixa os CSVs mensais de NFS-e de uma pasta pública do Google Drive, corrige o encoding e salva na camada bronze.
- `pre_processamento/`: limpa, tipa e enriquece os dados da bronze (via fuzzy matching contra as bases gold `base_bairros`, `base_municipios` e `base_cnae`) para a camada silver.
- `processamento/`: agrega a silver e calcula os indicadores econômicos para a camada gold.
- `turismo_serra.py`: DAG do Airflow que encadeia as três etapas (`coleta -> pre_processamento -> processamento`).
- `turismo_serra.Rproj`: projeto R usado no desenvolvimento local dos scripts.

## Fluxo do pipeline

1. Coleta: Google Drive (CSVs de NFS-e) -> `bronze/turismo_serra/`
2. Pré-processamento: `bronze/turismo_serra/` + gold de referência (`base_bairros`, `base_municipios`, `base_cnae`) -> `silver/turismo_serra/`
3. Processamento: `silver/turismo_serra/` -> `gold/turismo_serra/`

## Convenção de camadas

- Bronze: CSVs de NFS-e como extraídos do Google Drive, sem tratamento.
- Silver: dados tipados, filtrados (a partir de jan/2024, sem outliers) e enriquecidos com bairro, município (prestação e tomador) e CNAE padronizados.
- Gold: indicadores consolidados para consumo:
  - `turismo_serra_indicadores_mensais_*.parquet`: faturamento, ISS, ticket médio e sazonalidade por mês.
  - `turismo_serra_indicadores_cnae_*.parquet`: faturamento por CNAE (seção/subclasse) por mês.
  - `turismo_serra_indicadores_origem_*.parquet`: faturamento por origem do consumo (interno vs. externo).
  - `turismo_serra_detalhe_*.parquet`: silver enriquecida com os indicadores mensais.
