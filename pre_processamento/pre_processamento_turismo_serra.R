# ==============================================================================
# Script: pre_processamento_turismo_serra.R (Silver)
# Objetivo: Limpeza, tipagem e enriquecimento via bases de referência Gold
#           (base_bairros, base_municipios, base_cnae) — leitura via read_parquet
# Entrada:  bronze/turismo_serra/turismo_serra_YYYYMMDD.parquet
#           gold/base_bairros/gold_bairros_YYYYMMDD.parquet
#           gold/base_municipios/gold_municipios_YYYYMMDD.parquet
#           gold/base_cnae/gold_cnae_YYYYMMDD.parquet
# Saída:    silver/turismo_serra/turismo_serra_YYYYMMDD.parquet
# ==============================================================================

library(dplyr)
library(stringr)
library(stringi)
library(stringdist)
library(lubridate)
source("utils.R")

Sys.setlocale("LC_ALL", "C.UTF-8")

# ------------------------------------------------------------------------------
# 0. Utilitários
# ------------------------------------------------------------------------------
normalizar_texto <- function(x) {
  x |> stri_trans_general("Latin-ASCII") |> str_to_upper() |> str_squish()
}

normalizar_cod_cnae <- function(x) {
  str_remove_all(str_squish(x), "[.\\-/\\s]")
}

normalizar_uf <- function(x) {
  mapa <- c(
    "AC" = "AC", "ACRE" = "AC", "AL" = "AL", "ALAGOAS" = "AL",
    "AP" = "AP", "AMAPA" = "AP", "AM" = "AM", "AMAZONAS" = "AM",
    "BA" = "BA", "BAHIA" = "BA", "CE" = "CE", "CEARA" = "CE",
    "DF" = "DF", "DISTRITO FEDERAL" = "DF", "ES" = "ES", "ESPIRITO SANTO" = "ES",
    "GO" = "GO", "GOIAS" = "GO", "MA" = "MA", "MARANHAO" = "MA",
    "MT" = "MT", "MATO GROSSO" = "MT", "MS" = "MS", "MATO GROSSO DO SUL" = "MS",
    "MG" = "MG", "MINAS GERAIS" = "MG", "PA" = "PA", "PARA" = "PA",
    "PB" = "PB", "PARAIBA" = "PB", "PR" = "PR", "PARANA" = "PR",
    "PE" = "PE", "PERNAMBUCO" = "PE", "PI" = "PI", "PIAUI" = "PI",
    "RJ" = "RJ", "RIO DE JANEIRO" = "RJ", "RN" = "RN", "RIO GRANDE DO NORTE" = "RN",
    "RS" = "RS", "RIO GRANDE DO SUL" = "RS", "RO" = "RO", "RONDONIA" = "RO",
    "RR" = "RR", "RORAIMA" = "RR", "SC" = "SC", "SANTA CATARINA" = "SC",
    "SP" = "SP", "SAO PAULO" = "SP", "SE" = "SE", "SERGIPE" = "SE",
    "TO" = "TO", "TOCANTINS" = "TO"
  )
  chave <- normalizar_texto(x)
  unname(mapa[chave])
}

#' Corrige valores monetários vindos de fontes com formatos numéricos distintos.
#'
#' Os CSVs de origem misturam dois padrões (dependendo do sistema exportador):
#'   - Formato BR: "62.000,00" (ponto = milhar, vírgula = decimal)
#'   - Formato US: "437.5"     (ponto = decimal, sem separador de milhar)
#'
#' A regra: se o valor tem vírgula, é BR (remove pontos de milhar, troca
#' vírgula por ponto). Se não tem vírgula, é assumido US e mantido como está.
corrigir_valores <- function(x) {
  x <- str_squish(str_remove_all(x, "[R$\\s]"))
  x <- if_else(
    str_detect(x, ","),
    str_replace_all(str_remove_all(x, "\\."), ",", "."),
    x
  )
  as.numeric(x)
}

#' Faz fuzzy matching de uma lista de valores brutos contra uma base de
#' referência, usando similaridade Jaro-Winkler.
#'
#' Estratégia em duas etapas (eficiente mesmo com milhões de linhas):
#'   1. Join exato primeiro (valores já normalizados que batem 100%)
#'   2. Para os valores distintos que sobraram sem match, calcula a
#'      similaridade contra TODOS os candidatos da referência e escolhe
#'      o mais parecido. Só aceita se estiver acima do threshold.
#'
#' Quando a confiança é baixa (abaixo do threshold), o valor original é
#' mantido (não descartamos o dado) e uma flag de baixa confiança é marcada.
#'
#' @param valores_brutos   vetor de valores únicos a resolver (já normalizados)
#' @param referencia       vetor de valores únicos da base oficial (já normalizados)
#' @param threshold         similaridade mínima (0 a 1) para aceitar o match
#'
#' @return data.frame com colunas: valor_bruto, valor_match (NA se sem match),
#'         similaridade, confianca_alta (lógico)
fuzzy_match_lookup <- function(valores_brutos, referencia, threshold = 0.85) {
  valores_unicos <- unique(valores_brutos[!is.na(valores_brutos) & valores_brutos != ""])
  
  # Etapa 1: join exato
  match_exato <- valores_unicos %in% referencia
  
  resultado <- tibble::tibble(
    valor_bruto = valores_unicos,
    valor_match = if_else(match_exato, valores_unicos, NA_character_),
    similaridade = if_else(match_exato, 1, NA_real_)
  )
  
  # Etapa 2: fuzzy matching só para quem não bateu exato
  pendentes <- resultado$valor_bruto[is.na(resultado$valor_match)]
  
  if (length(pendentes) > 0 && length(referencia) > 0) {
    # Matriz de distância Jaro-Winkler entre pendentes e toda a referência
    dist_matrix <- stringdist::stringdistmatrix(
      pendentes, referencia, method = "jw", p = 0.1
    )
    similaridade_matrix <- 1 - dist_matrix
    
    idx_melhor <- apply(similaridade_matrix, 1, which.max)
    sim_melhor <- apply(similaridade_matrix, 1, max)
    
    fuzzy_resultado <- tibble::tibble(
      valor_bruto  = pendentes,
      valor_match  = referencia[idx_melhor],
      similaridade = sim_melhor
    )
    
    resultado <- resultado |>
      filter(!is.na(valor_match)) |>
      bind_rows(fuzzy_resultado)
  }
  
  resultado |>
    mutate(
      confianca_alta = similaridade >= threshold,
      # Se confiança baixa, mantém o valor ORIGINAL (não o match arriscado)
      valor_final = if_else(confianca_alta, valor_match, valor_bruto)
    )
}

#' Identifica outliers estatísticos (> 3 desvios-padrão da média) para remoção.
marcar_outliers <- function(x) {
  media  <- mean(x, na.rm = TRUE)
  desvio <- sd(x, na.rm = TRUE)
  limite_superior <- media + 3 * desvio
  limite_inferior <- media - 3 * desvio
  
  is_outlier <- !is.na(x) & (x > limite_superior | x < limite_inferior)
  list(
    flag = is_outlier,
    limite_inferior = limite_inferior,
    limite_superior = limite_superior
  )
}

fuzzy_match_lookup_uf <- function(cidades, ufs, referencia, threshold = 0.85) {
  entradas <- tibble::tibble(valor_bruto = cidades, uf = ufs) |>
    filter(!is.na(valor_bruto), valor_bruto != "") |>
    distinct()

  resultados <- list()
  for (uf_atual in unique(entradas$uf[!is.na(entradas$uf)])) {
    valores_uf <- entradas |> filter(uf == uf_atual) |> pull(valor_bruto)
    referencias_uf <- referencia |>
      filter(sigla_uf_padronizada == uf_atual) |>
      pull(nome_municipio)
    resultados[[uf_atual]] <- fuzzy_match_lookup(
      valores_uf, referencias_uf, threshold
    ) |>
      mutate(uf = uf_atual)
  }

  sem_uf <- entradas |> filter(is.na(uf)) |> pull(valor_bruto)
  if (length(sem_uf) > 0) {
    referencias_unicas <- referencia |>
      group_by(nome_municipio) |>
      filter(n() == 1) |>
      ungroup() |>
      pull(nome_municipio)
    resultados[["SEM_UF"]] <- fuzzy_match_lookup(
      sem_uf, referencias_unicas, threshold
    ) |>
      mutate(uf = NA_character_)
  }

  bind_rows(resultados)
}

# ------------------------------------------------------------------------------
# 1. Leitura: Bronze e bases de referência via utils.R
# ------------------------------------------------------------------------------
read_inputs <- function() {
  cat("[SILVER] Carregando Bronze e bases de referência...\n")
  
  bronze     <- read_latest_parquet_from_minio("bronze/turismo_serra/")
  bairros    <- read_latest_parquet_from_minio("gold/base_bairros/")
  municipios <- read_latest_parquet_from_minio("gold/base_municipios/")
  cnae       <- read_latest_parquet_from_minio("gold/base_cnae/")
  
  if (is.null(bronze))     stop("Nenhum arquivo bronze encontrado.")
  if (is.null(bairros))    stop("Nenhum arquivo gold/base_bairros encontrado.")
  if (is.null(municipios)) stop("Nenhum arquivo gold/base_municipios encontrado.")
  if (is.null(cnae))       stop("Nenhum arquivo gold/base_cnae encontrado.")
  
  list(bronze = bronze, bairros = bairros, municipios = municipios, cnae = cnae)
}

# ------------------------------------------------------------------------------
# 2. Processamento
# ------------------------------------------------------------------------------
process_data <- function(bronze, ref_bairros, ref_municipios, ref_cnae) {
  cat(sprintf("[SILVER] Processando %d registros...\n", nrow(bronze)))
  
  # 2.1 Tipagem, filtro de período e marcação de outliers
  dados <- bronze |>
    mutate(
      vlrservicos   = corrigir_valores(vlrservicos),
      iss           = corrigir_valores(iss),
      totalliquido  = corrigir_valores(totalliquido),
      mesreferencia = as.integer(mesreferencia),
      anoreferencia = as.integer(anoreferencia),
      dtprestacao   = as.Date(dtprestacao)
    )
  
  n_total <- nrow(dados)
  n_sem_periodo <- sum(is.na(dados$anoreferencia) | is.na(dados$mesreferencia))
  if (n_sem_periodo > 0) {
    cat(sprintf(
      "[SILVER][AVISO] %d de %d registro(s) com anoreferencia/mesreferencia inválido (não numérico) — serão descartados pelo filtro de período.\n",
      n_sem_periodo, n_total
    ))
  }
  
  # Diagnóstico: quantifica a perda de cada filtro isoladamente, para saber
  # qual está descartando mais — valor inválido/zero, ou período fora de jan/2024+.
  n_falha_valor   <- sum(is.na(dados$vlrservicos) | dados$vlrservicos <= 0)
  n_falha_periodo <- sum(
    !is.na(dados$anoreferencia) & !is.na(dados$mesreferencia) &
      !(dados$anoreferencia > 2024 | (dados$anoreferencia == 2024 & dados$mesreferencia >= 1))
  )
  cat(sprintf(
    "[SILVER] Diagnóstico de filtros (não cumulativo): %d registro(s) com valor inválido/zero | %d registro(s) com período anterior a jan/2024.\n",
    n_falha_valor, n_falha_periodo
  ))
  
  # Distribuição por ano, para visualizar de onde vêm os dados do Bronze
  distrib_ano <- dados |>
    filter(!is.na(anoreferencia)) |>
    count(anoreferencia, name = "qtd") |>
    arrange(anoreferencia)
  cat("[SILVER] Distribuição de registros por anoreferencia (Bronze, antes dos filtros):\n")
  for (i in seq_len(nrow(distrib_ano))) {
    cat(sprintf("           %s: %d registro(s)\n", distrib_ano$anoreferencia[i], distrib_ano$qtd[i]))
  }
  
  dados <- dados |>
    filter(!is.na(vlrservicos), vlrservicos > 0) |>
    # Apenas dados a partir de janeiro de 2024
    filter(!is.na(anoreferencia), !is.na(mesreferencia)) |>
    filter(anoreferencia > 2024 | (anoreferencia == 2024 & mesreferencia >= 1))
  
  cat(sprintf(
    "[SILVER] Após filtros de valor e período: %d de %d registros (%.1f%%) mantidos.\n",
    nrow(dados), n_total, 100 * nrow(dados) / n_total
  ))
  
  outliers_resultado <- marcar_outliers(dados$vlrservicos)
  n_outliers <- sum(outliers_resultado$flag, na.rm = TRUE)
  if (n_outliers > 0) {
    cat(sprintf(
      "[SILVER][AVISO] %d registro(s) identificado(s) como outlier (limite superior: R$ %.2f) e removido(s) da base analitica.\n",
      n_outliers, outliers_resultado$limite_superior
    ))
  }
  dados <- dados[!outliers_resultado$flag, , drop = FALSE]
  
  # 2.2 Chaves de join normalizadas (removidas ao final)
  #     key_cnae usa o nome do arquivo de origem (origem_arquivo), não o
  #     campo cnaeprestador da linha: o nome do CSV é sempre o código CNAE
  #     de 7 dígitos correto, enquanto o campo cnaeprestador vem com
  #     formatação inconsistente entre arquivos (alguns com dígito extra,
  #     ex: "5611-02-02" em vez de "5611-2/02").
  dados <- dados |>
    mutate(
      key_bairro     = normalizar_texto(prestadorbairro),
      key_cidade_tom = normalizar_texto(tomadorcidade),
      key_uf_tom     = normalizar_uf(tomadorestado),
      cod_cnae_arquivo = normalizar_cod_cnae(str_remove(origem_arquivo, "\\.csv$")),
      cod_cnae_nota    = normalizar_cod_cnae(cnaeprestador),
      cnae_divergente  = !is.na(cod_cnae_nota) & cod_cnae_nota != "" &
        cod_cnae_nota != cod_cnae_arquivo,
      key_cnae         = cod_cnae_arquivo
    )

  # --------------------------------------------------------------------------
  # 2.3 Enriquecimento: bairros — fuzzy matching contra bairros de Serra/ES
  #     (prestador é sempre de Serra; variações de grafia como "CIVIT I" vs
  #     "Civit I" vs "CIVIT1" são resolvidas por similaridade Jaro-Winkler)
  # --------------------------------------------------------------------------
  ref_bairros_serra <- ref_bairros |>
    filter(sigla_uf == "ES", nome_municipio == "SERRA") |>
    distinct(nome_bairro, cd_bairro, cd_municipio) |>
    # Garante 1 linha por nome_bairro (chave do próximo join) — se a base
    # gold tiver duplicidade no nome, mantém apenas a primeira ocorrência
    distinct(nome_bairro, .keep_all = TRUE)
  
  match_bairro <- fuzzy_match_lookup(
    valores_brutos = dados$key_bairro,
    referencia     = ref_bairros_serra$nome_bairro,
    threshold      = 0.85
  )
  
  dados <- dados |>
    left_join(
      match_bairro |> select(key_bairro = valor_bruto, bairro_padronizado = valor_final,
                             bairro_confianca_alta = confianca_alta, bairro_similaridade = similaridade),
      by = "key_bairro"
    ) |>
    left_join(
      ref_bairros_serra |> rename(bairro_padronizado = nome_bairro),
      by = "bairro_padronizado"
    )
  
  n_bairro_baixa_confianca <- sum(!match_bairro$confianca_alta, na.rm = TRUE)
  if (n_bairro_baixa_confianca > 0) {
    cat(sprintf(
      "[SILVER][AVISO] %d valor(es) distinto(s) de bairro com baixa confiança no fuzzy match (mantido valor original).\n",
      n_bairro_baixa_confianca
    ))
  }
  
  n_sem_bairro <- sum(is.na(dados$cd_bairro))
  if (n_sem_bairro > 0) {
    cat(sprintf("[SILVER][AVISO] %d registro(s) sem correspondência de bairro.\n", n_sem_bairro))
    
    # Diagnóstico: valores brutos mais frequentes sem correspondência,
    # para identificar se é erro de digitação, bairro inexistente na base
    # gold, ou campo vazio/nulo.
    top_valores_bairro <- dados |>
      filter(is.na(cd_bairro)) |>
      count(prestadorbairro, bairro_padronizado, sort = TRUE) |>
      head(15)
    cat("[SILVER] Top valores brutos de 'prestadorbairro' sem correspondência:\n")
    for (i in seq_len(nrow(top_valores_bairro))) {
      cat(sprintf(
        "           bruto='%s' -> padronizado='%s' (%d registro(s))\n",
        top_valores_bairro$prestadorbairro[i],
        top_valores_bairro$bairro_padronizado[i],
        top_valores_bairro$n[i]
      ))
    }
  }
  
  # --------------------------------------------------------------------------
  # 2.4 Enriquecimento: município informado em prestacaoservico e município
  #     do tomador. Prestacaoservico é padronizado, mas não determina incidência,
  #     domicílio do prestador ou elegibilidade da nota.
  # --------------------------------------------------------------------------
  ref_mun <- ref_municipios |>
    select(
      nome_municipio,
      cod_uf,
      cod_ibge_7,
      sigla_uf,
      cod_regiao_intermediaria,
      nome_regiao_intermediaria,
      cod_regiao_imediata,
      nome_regiao_imediata
    ) |>
    mutate(
      nome_municipio = normalizar_texto(nome_municipio),
      sigla_uf_padronizada = normalizar_uf(sigla_uf)
    ) |>
    filter(!is.na(sigla_uf_padronizada)) |>
    distinct(sigla_uf_padronizada, nome_municipio, .keep_all = TRUE)

  ref_mun_unicos <- ref_mun |>
    group_by(nome_municipio) |>
    filter(n() == 1) |>
    ungroup()
  
  dados <- dados |>
    mutate(key_cidade_prest = normalizar_texto(prestacaoservico))
  
  match_cidade_prest <- fuzzy_match_lookup(
    valores_brutos = dados$key_cidade_prest,
    referencia     = ref_mun_unicos$nome_municipio,
    threshold      = 0.85
  )
  
  dados <- dados |>
    left_join(
      match_cidade_prest |> select(key_cidade_prest = valor_bruto, cidade_prest_padronizada = valor_final,
                                   prest_confianca_alta = confianca_alta),
      by = "key_cidade_prest"
    ) |>
    left_join(
      ref_mun_unicos |> rename(cidade_prest_padronizada = nome_municipio) |>
        rename_with(~ paste0(.x, "_prest"), -cidade_prest_padronizada),
      by = "cidade_prest_padronizada"
    ) |>
    select(-key_cidade_prest)
  
  n_prest_baixa_confianca <- sum(!match_cidade_prest$confianca_alta, na.rm = TRUE)
  if (n_prest_baixa_confianca > 0) {
    cat(sprintf(
      "[SILVER][AVISO] %d valor(es) distinto(s) de local de prestação com baixa confiança no fuzzy match (mantido valor original).\n",
      n_prest_baixa_confianca
    ))
  }
  
  n_local_fora_serra <- sum(dados$cidade_prest_padronizada != "SERRA", na.rm = TRUE)
  if (n_local_fora_serra > 0) {
    cat(sprintf(
      "[SILVER] %d registro(s) informam municipio de prestacao diferente de Serra; os registros serao mantidos porque o campo nao comprova incidencia nem domicilio do prestador.\n",
      n_local_fora_serra
    ))
  }

  n_local_sem_match <- sum(
    is.na(dados$cidade_prest_padronizada) | dados$cidade_prest_padronizada == ""
  )
  if (n_local_sem_match > 0) {
    cat(sprintf(
      "[SILVER][AVISO] %d registro(s) sem municipio de prestacao identificado serao mantidos com o valor original.\n",
      n_local_sem_match
    ))
  }

  dados <- dados |>
    mutate(municipio_prestacao = cidade_prest_padronizada)
  
  # --- Tomador: usa cidade + UF para evitar municípios homônimos.
  match_cidade_tom <- fuzzy_match_lookup_uf(
    cidades    = dados$key_cidade_tom,
    ufs        = dados$key_uf_tom,
    referencia = ref_mun,
    threshold  = 0.85
  )
  
  dados <- dados |>
    left_join(
      match_cidade_tom |> select(
        key_cidade_tom = valor_bruto,
        key_uf_tom = uf,
        cidade_tom_padronizada = valor_final,
        tom_confianca_alta = confianca_alta,
        tom_similaridade = similaridade
      ),
      by = c("key_cidade_tom", "key_uf_tom")
    ) |>
    left_join(
      ref_mun |>
        rename(cidade_tom_padronizada = nome_municipio) |>
        rename_with(
          ~ paste0(.x, "_tom"),
          -c(cidade_tom_padronizada, sigla_uf_padronizada)
        ),
      by = c(
        "cidade_tom_padronizada",
        "key_uf_tom" = "sigla_uf_padronizada"
      )
    )

  n_tom_baixa_confianca <- sum(!match_cidade_tom$confianca_alta, na.rm = TRUE)
  if (n_tom_baixa_confianca > 0) {
    cat(sprintf(
      "[SILVER][AVISO] %d combinacao(oes) distinta(s) de cidade/UF do tomador com baixa confianca; mantido o valor original.\n",
      n_tom_baixa_confianca
    ))
  }
  
  # --------------------------------------------------------------------------
  # 2.5 Enriquecimento: CNAE — código + nome padronizados lado a lado
  #     (substitui descrcnae, que vem com encoding quebrado da fonte)
  # --------------------------------------------------------------------------
  ref_cnae_lookup <- ref_cnae |>
    mutate(key_cnae = normalizar_cod_cnae(cod_subclasse)) |>
    arrange(key_cnae, desc(versao_cnae)) |>
    select(
      key_cnae,
      cod_cnae    = cod_subclasse,   # código oficial, formatado (ex: "5611-2/02")
      nome_cnae   = nome_subclasse,  # nome oficial, encoding correto
      versao_cnae, cod_secao, cod_divisao, cod_grupo, cod_classe
    ) |>
    distinct(key_cnae, .keep_all = TRUE)
  
  dados <- dados |>
    left_join(ref_cnae_lookup, by = "key_cnae") |>
    select(-descrcnae)  # substituído por cod_cnae + nome_cnae (encoding correto)
  
  n_sem_cnae <- sum(is.na(dados$nome_cnae))
  if (n_sem_cnae > 0)
    cat(sprintf("[SILVER][AVISO] %d registro(s) sem correspondência de CNAE.\n", n_sem_cnae))

  n_cnae_divergente <- sum(dados$cnae_divergente, na.rm = TRUE)
  if (n_cnae_divergente > 0) {
    cat(sprintf(
      "[SILVER][AVISO] %d registro(s) com divergencia entre a CNAE da nota e a CNAE do arquivo; a CNAE do arquivo foi usada como referencia.\n",
      n_cnae_divergente
    ))
  }
  
  # --------------------------------------------------------------------------
  # 2.6 Classificação de origem do consumo (usa cidade já padronizada)
  # --------------------------------------------------------------------------
  dados <- dados |>
    mutate(
      municipio_tomador = cidade_tom_padronizada,
      uf_tomador = key_uf_tom,
      origem_cliente = case_when(
        is.na(cidade_tom_padronizada) | cidade_tom_padronizada == "" ~ NA_character_,
        cidade_tom_padronizada == "SERRA" ~ "Consumo Interno",
        TRUE ~ "Consumo Externo"
      )
    )
  
  # 2.7 Remove chaves auxiliares
  dados <- dados |> select(-starts_with("key_"))
  
  # --------------------------------------------------------------------------
  # 2.8 Normalização final: NFC (forma Unicode composta) + maiúsculo em
  #     TODAS as colunas de texto.
  #
  #     Causa raiz dos acentos quebrados (~, ^, ´, `, ç aparecendo soltos):
  #     dados vindos de fontes diferentes (CSVs da prefeitura + bases gold)
  #     misturam duas representações Unicode visualmente idênticas mas
  #     binariamente diferentes — NFC (1 caractere: "ã") e NFD (2 caracteres:
  #     "a" + acento combinante solto). Ao concatenar fontes (bind_rows,
  #     left_join), as duas formas convivem sem nunca serem unificadas.
  #     stri_trans_nfc() força tudo para a forma composta (NFC), eliminando
  #     o acento "solto" residual.
  dados <- dados |>
    mutate(across(where(is.character), ~ stri_trans_nfc(.x) |> str_to_upper()))
  
  cat(sprintf("[SILVER] Registros finais: %d\n", nrow(dados)))
  dados
}

# ------------------------------------------------------------------------------
# 3. Gravação Silver
# ------------------------------------------------------------------------------
salvar_silver <- function(data) {
  filepath <- sprintf("silver/turismo_serra/turismo_serra_%s.parquet", format(Sys.time(), "%Y%m%d"))
  cat(sprintf("[SILVER] Salvando em: %s\n", filepath))
  write_parquet_to_minio(data, filepath)
  filepath
}

# ------------------------------------------------------------------------------
# 4. Execução
# ------------------------------------------------------------------------------
tryCatch({
  message("--- INICIANDO PRÉ-PROCESSAMENTO TURISMO SERRA ---")
  inputs <- read_inputs()
  silver <- process_data(
    bronze         = inputs$bronze,
    ref_bairros    = inputs$bairros,
    ref_municipios = inputs$municipios,
    ref_cnae       = inputs$cnae
  )
  saida <- salvar_silver(silver)
  cat(sprintf("[SILVER] Concluído: %s | %d registros\n", saida, nrow(silver)))
}, error = function(e) {
  cat("[SILVER] Erro crítico:", conditionMessage(e), "\n")
  quit(status = 1)
})
