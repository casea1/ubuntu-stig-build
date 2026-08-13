# MLflow tracking/registry image with the Postgres driver added (the upstream
# image ships only SQLite support). Built on the box by ansible (ai_compose).
# Tag: mlflow:v3.15.1-psycopg2  (see group_vars ai_compose_images).
FROM ghcr.io/mlflow/mlflow:v3.15.1

RUN pip install --no-cache-dir psycopg2-binary
