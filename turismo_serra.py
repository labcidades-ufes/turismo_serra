from datetime import datetime, timedelta
from airflow import DAG
from airflow.providers.docker.operators.docker import DockerOperator
from docker.types import Mount
import os

default_args = {
    "owner": "airflow",
    "depends_on_past": False,
    "start_date": datetime(2024, 1, 1),
    "email_on_failure": False,
    "email_on_retry": False,
    "retries": 1,
    "retry_delay": timedelta(minutes=5),
}

docker_network = os.getenv("DOCKER_NETWORK")

# Variáveis de ambiente repassadas para todos os containers
minio_env = {
    "MINIO_ENDPOINT":   os.getenv("MINIO_ENDPOINT",   "minio:9000"),
    "MINIO_ACCESS_KEY": os.getenv("MINIO_ACCESS_KEY", "minioadmin"),
    "MINIO_SECRET_KEY": os.getenv("MINIO_SECRET_KEY", "minioadmin"),
    "MINIO_BUCKET":     os.getenv("MINIO_BUCKET",     "airflow"),
    "MINIO_USE_SSL":    os.getenv("MINIO_USE_SSL",    "false"),
}

with DAG(
    dag_id="turismo_serra",
    schedule=None,
    catchup=False,
    default_args=default_args,
    tags=["turismo", "serra", "iss"],
) as dag:

    # 1. Fase Bronze: Extração dos CSVs para o MinIO
    coleta = DockerOperator(
        task_id="coleta_turismo_serra",
        image="turismo_serra-coleta:latest",
        api_version="auto",
        auto_remove="success",
        docker_url="unix://var/run/docker.sock",
        network_mode=docker_network,
        mount_tmp_dir=False,
        environment=minio_env,
    )

    # 2. Fase Silver: Limpeza e Tipagem
    pre_processamento = DockerOperator(
        task_id="pre_processamento_turismo_serra",
        image="turismo_serra-pre_processamento:latest",
        api_version="auto",
        auto_remove="success",
        docker_url="unix://var/run/docker.sock",
        network_mode=docker_network,
        mount_tmp_dir=False,
        environment=minio_env,
    )

    # 3. Fase Gold: Indicadores Econômicos
    processamento = DockerOperator(
        task_id="processamento_turismo_serra",
        image="turismo_serra-processamento:latest",
        api_version="auto",
        auto_remove="success",
        docker_url="unix://var/run/docker.sock",
        network_mode=docker_network,
        mount_tmp_dir=False,
        environment=minio_env,
    )

    coleta >> pre_processamento >> processamento
