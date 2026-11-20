# LiteLLM model router, pinned. Routes only to lumo-tamer (see litellm-config.yaml).
FROM python:3.12-slim
ARG LITELLM_VERSION=1.110.2
RUN pip install --no-cache-dir --disable-pip-version-check "litellm[proxy]==${LITELLM_VERSION}" \
 && useradd -m -u 1000 lumo
USER lumo
EXPOSE 4000
CMD ["litellm", "--config", "/config/config.yaml", "--host", "0.0.0.0", "--port", "4000"]
