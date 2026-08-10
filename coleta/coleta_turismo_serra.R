# ==============================================================================
# Script: coleta_turismo_serra.R (Bronze)
# Objetivo: Coletar CSVs do Google Drive, corrigir encoding e gravar Bronze
# Entrada:  Google Drive (pasta pública) — CSVs mensais de NFS-e
# Saída:    bronze/turismo_serra/turismo_serra_YYYYMMDD.parquet
# ==============================================================================

library(googledrive)
library(dplyr)
library(httr)
source("utils.R")

Sys.setlocale("LC_ALL", "C.UTF-8")
drive_deauth()
set_config(add_headers(`User-Agent` = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"))

ID_PASTA <- "1IB6MeE8q9UlgGaABJ1sSBh4CRqQTY89p"

# ------------------------------------------------------------------------------
# 1. Listagem dos arquivos no Google Drive
# ------------------------------------------------------------------------------
listar_arquivos_drive <- function(folder_id) {
  cat("[BRONZE] Listando arquivos no Google Drive...\n")
  # n_max = Inf garante que toda a pasta seja listada, mesmo com muitos arquivos
  # (evita perda silenciosa de CNAEs/períodos por paginação incompleta)
  arquivos <- drive_ls(as_id(folder_id), pattern = "\\.csv$", n_max = Inf)
  if (nrow(arquivos) == 0) stop("[BRONZE] Nenhum CSV encontrado na pasta.")
  cat(sprintf("[BRONZE] %d arquivo(s) encontrado(s) na pasta.\n", nrow(arquivos)))
  arquivos
}

#' Detecta se um arquivo é UTF-8 válido sem lançar erro em bytes problemáticos
#' (rawToChar quebra com bytes nulos/sequências inválidas vindas de downloads
#' truncados — por isso readLines + iconv, que são tolerantes a isso).
detectar_encoding <- function(path) {
  texto <- tryCatch(
    readLines(path, warn = FALSE, encoding = "bytes"),
    error = function(e) NULL
  )
  if (is.null(texto) || length(texto) == 0) return("UTF-8")  # fallback seguro
  
  amostra <- paste(head(texto, 50), collapse = "\n")
  convertido <- iconv(amostra, from = "UTF-8", to = "UTF-8", sub = NA)
  if (is.na(convertido)) "ISO-8859-1" else "UTF-8"
}

#' Baixa um arquivo do Drive com retry, pois a rede para o Google Drive
#' apresenta falhas intermitentes (timeouts/conexões resetadas).
baixar_com_retry <- function(url, destino, tentativas = 3) {
  for (tentativa in seq_len(tentativas)) {
    resultado <- tryCatch({
      resp <- GET(url, write_disk(destino, overwrite = TRUE), timeout(60))
      if (http_error(resp)) stop(sprintf("HTTP %s", status_code(resp)))
      # Confere se o arquivo baixado tem conteúdo (download não truncou em 0 bytes)
      if (file.info(destino)$size == 0) stop("Arquivo baixado está vazio")
      TRUE
    }, error = function(e) {
      cat(sprintf("    [tentativa %d/%d] falhou: %s\n", tentativa, tentativas, conditionMessage(e)))
      FALSE
    })
    if (isTRUE(resultado)) return(invisible(TRUE))
    if (tentativa < tentativas) Sys.sleep(2 * tentativa)  # backoff progressivo
  }
  stop(sprintf("Download falhou após %d tentativas", tentativas))
}

# ------------------------------------------------------------------------------
# 2. Download e leitura de um CSV com correção de encoding
# ------------------------------------------------------------------------------
ler_csv_drive <- function(item, i, total) {
  cat(sprintf("  -> [%d/%d] %s\n", i, total, item$name))
  temp_csv <- tempfile(fileext = ".csv")
  on.exit(unlink(temp_csv))
  
  url <- sprintf("https://docs.google.com/uc?export=download&id=%s", item$id)
  baixar_com_retry(url, temp_csv)
  
  # Detecta o encoding real do arquivo. Arquivos exportados por sistemas
  # diferentes da prefeitura usam encodings diferentes (alguns UTF-8,
  # outros Latin-1/Windows-1252) — não dá para supor.
  encoding_real <- detectar_encoding(temp_csv)
  
  d <- read.csv(
    temp_csv,
    stringsAsFactors = FALSE,
    sep              = ";",
    dec              = ",",
    colClasses       = "character",
    check.names      = FALSE,
    fileEncoding     = encoding_real
  )
  
  # Garante que todas as colunas de texto fiquem marcadas e convertidas para UTF-8
  d[] <- lapply(d, function(x) enc2utf8(x))
  
  d$origem_arquivo <- item$name
  d
}

# ------------------------------------------------------------------------------
# 3. Coleta completa
# ------------------------------------------------------------------------------
coletar <- function(folder_id) {
  arquivos    <- listar_arquivos_drive(folder_id)
  total       <- nrow(arquivos)
  lista_dados <- vector("list", total)
  falhas      <- character(0)
  
  for (i in seq_len(total)) {
    lista_dados[[i]] <- tryCatch(
      ler_csv_drive(arquivos[i, ], i, total),
      error = function(e) {
        cat(sprintf("[BRONZE][ERRO] Falha ao ler %s: %s\n", arquivos$name[i], conditionMessage(e)))
        falhas <<- c(falhas, arquivos$name[i])
        NULL
      }
    )
  }
  
  # Não seguimos silenciosamente: se algum arquivo falhou, a coleta fica
  # incompleta (faltaria CNAE/período) — melhor parar e investigar.
  if (length(falhas) > 0) {
    stop(sprintf(
      "Falha ao coletar %d de %d arquivo(s): %s",
      length(falhas), total, paste(falhas, collapse = ", ")
    ))
  }
  
  dados <- bind_rows(lista_dados)
  cat(sprintf("[BRONZE] %d registros coletados de %d arquivo(s) (100%% da pasta).\n", nrow(dados), total))
  dados
}

# ------------------------------------------------------------------------------
# 4. Gravação na camada Bronze
# ------------------------------------------------------------------------------
salvar_bronze <- function(data) {
  filepath <- sprintf("bronze/turismo_serra/turismo_serra_%s.parquet", format(Sys.time(), "%Y%m%d"))
  cat(sprintf("[BRONZE] Salvando em: %s\n", filepath))
  write_parquet_to_minio(data, filepath)
  filepath
}

# ------------------------------------------------------------------------------
# 5. Execução
# ------------------------------------------------------------------------------
tryCatch({
  message("--- INICIANDO COLETA TURISMO SERRA ---")
  dados_brutos <- coletar(ID_PASTA)
  saida        <- salvar_bronze(dados_brutos)
  cat(sprintf("[BRONZE] Concluído: %s | %d registros\n", saida, nrow(dados_brutos)))
}, error = function(e) {
  cat("[BRONZE] Erro crítico:", conditionMessage(e), "\n")
  quit(status = 1)
})
