# ==============================================================================
# Script: processamento_turismo_serra.R (Gold)
# Objetivo: Calcular indicadores econômicos de turismo e gravar camada Gold
# Entrada:  silver/turismo_serra/turismo_serra_YYYYMMDD.parquet
# Saída:    gold/turismo_serra/turismo_serra_indicadores_YYYYMMDD.parquet
#           gold/turismo_serra/turismo_serra_detalhe_YYYYMMDD.parquet
# ==============================================================================

library(dplyr)
library(lubridate)
library(tidyr)
library(arrow)
source("utils.R")

Sys.setlocale("LC_ALL", "C.UTF-8")

MESES_ABREV    <- c("Jan","Fev","Mar","Abr","Mai","Jun","Jul","Ago","Set","Out","Nov","Dez")
MESES_COMPLETO <- c("Janeiro","Fevereiro","Março","Abril","Maio","Junho",
                    "Julho","Agosto","Setembro","Outubro","Novembro","Dezembro")

# ------------------------------------------------------------------------------
# 1. Leitura da Silver
# ------------------------------------------------------------------------------
ler_silver <- function() {
  cat("[GOLD] Lendo Silver...\n")
  arquivos <- list_parquet_files_in_minio("silver/turismo_serra/")
  if (length(arquivos) == 0) stop("Nenhum arquivo silver encontrado.")
  caminho <- sub(
    sprintf("^s3://%s/", Sys.getenv("MINIO_BUCKET", "airflow")), "",
    sort(arquivos, decreasing = TRUE)[1]
  )
  cat(sprintf("[GOLD] Lendo: %s\n", caminho))
  read_parquet_from_minio(caminho)
}

# ------------------------------------------------------------------------------
# 2. Indicadores mensais agregados
# ------------------------------------------------------------------------------
calcular_indicadores_mensais <- function(dados) {
  cat("[GOLD] Calculando indicadores mensais...\n")
  
  dados |>
    mutate(
      ano = as.integer(anoreferencia),
      mes = as.integer(mesreferencia),
      data_referencia = as.Date(sprintf("%d-%02d-01", as.integer(anoreferencia), as.integer(mesreferencia)))
    ) |>
    group_by(ano, mes, data_referencia) |>
    summarise(
      faturamento_mensal   = sum(vlrservicos, na.rm = TRUE),
      total_iss            = sum(iss, na.rm = TRUE),
      qtd_operacoes        = n(),
      ticket_medio         = mean(vlrservicos, na.rm = TRUE),
      qtd_consumo_interno  = sum(origem_cliente == "Consumo Interno",  na.rm = TRUE),
      qtd_consumo_externo  = sum(origem_cliente == "Consumo Externo", na.rm = TRUE),
      .groups = "drop"
    ) |>
    arrange(ano, mes) |>
    mutate(
      # Índice de atividade: evolução relativa ao primeiro mês da série
      indice_atividade  = faturamento_mensal / first(faturamento_mensal[faturamento_mensal > 0]),
      # Sazonalidade: desvio em relação à média histórica
      variacao_sazonal  = (faturamento_mensal / mean(faturamento_mensal)) - 1,
      # Variação mês a mês
      variacao_mom      = (faturamento_mensal / lag(faturamento_mensal)) - 1,
      # Labels de visualização
      mes_abrev  = factor(MESES_ABREV[mes],    levels = MESES_ABREV),
      mes_nome   = factor(MESES_COMPLETO[mes], levels = MESES_COMPLETO)
    )
}

# ------------------------------------------------------------------------------
# 3. Indicadores por CNAE (seção e subclasse)
# ------------------------------------------------------------------------------
calcular_indicadores_cnae <- function(dados) {
  cat("[GOLD] Calculando indicadores por CNAE...\n")
  
  dados |>
    filter(!is.na(cod_secao)) |>
    mutate(
      ano = as.integer(anoreferencia),
      mes = as.integer(mesreferencia)
    ) |>
    group_by(ano, mes, cod_secao, cod_divisao, cod_cnae, nome_cnae, versao_cnae) |>
    summarise(
      faturamento  = sum(vlrservicos, na.rm = TRUE),
      qtd_notas    = n(),
      .groups = "drop"
    ) |>
    arrange(ano, mes, desc(faturamento))
}

# ------------------------------------------------------------------------------
# 4. Indicadores por origem do consumo (interno vs externo)
# ------------------------------------------------------------------------------
calcular_indicadores_origem <- function(dados) {
  cat("[GOLD] Calculando indicadores por origem do consumo...\n")
  
  dados |>
    filter(!is.na(origem_cliente)) |>
    mutate(
      ano = as.integer(anoreferencia),
      mes = as.integer(mesreferencia)
    ) |>
    group_by(ano, mes, origem_cliente) |>
    summarise(
      faturamento = sum(vlrservicos, na.rm = TRUE),
      qtd_notas   = n(),
      .groups = "drop"
    ) |>
    arrange(ano, mes, origem_cliente)
}

# ------------------------------------------------------------------------------
# 5. Tabela detalhe (Silver enriquecida com campos Gold)
# ------------------------------------------------------------------------------
construir_detalhe <- function(dados, indicadores_mensais) {
  cat("[GOLD] Construindo tabela detalhe...\n")
  
  dados |>
    mutate(
      ano = as.integer(anoreferencia),
      mes = as.integer(mesreferencia)
    ) |>
    left_join(
      indicadores_mensais |>
        select(ano, mes, indice_atividade, variacao_sazonal, variacao_mom,
               mes_abrev, mes_nome),
      by = c("ano", "mes")
    )
}

# ------------------------------------------------------------------------------
# 6. Gravação Gold
# ------------------------------------------------------------------------------
salvar_gold <- function(data, sufixo) {
  filepath <- sprintf(
    "gold/turismo_serra/turismo_serra_%s_%s.parquet",
    sufixo,
    format(Sys.time(), "%Y%m%d")
  )
  cat(sprintf("[GOLD] Salvando: %s\n", filepath))
  write_parquet_to_minio(data, filepath)
  filepath
}

# ------------------------------------------------------------------------------
# 7. Execução
# ------------------------------------------------------------------------------
tryCatch({
  message("--- INICIANDO PROCESSAMENTO TURISMO SERRA ---")
  
  silver <- ler_silver()
  
  indicadores_mensais <- calcular_indicadores_mensais(silver)
  indicadores_cnae    <- calcular_indicadores_cnae(silver)
  indicadores_origem  <- calcular_indicadores_origem(silver)
  detalhe             <- construir_detalhe(silver, indicadores_mensais)
  
  salvar_gold(indicadores_mensais, "indicadores_mensais")
  salvar_gold(indicadores_cnae,    "indicadores_cnae")
  salvar_gold(indicadores_origem,  "indicadores_origem")
  salvar_gold(detalhe,             "detalhe")
  
  cat(sprintf(
    "[GOLD] Concluído: %d meses | %d registros no detalhe\n",
    nrow(indicadores_mensais),
    nrow(detalhe)
  ))
}, error = function(e) {
  cat("[GOLD] Erro crítico:", conditionMessage(e), "\n")
  quit(status = 1)
})
