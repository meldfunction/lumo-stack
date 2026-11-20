# Lumo Home: dashboard (status, sign-in, files). No Docker access.
FROM python:3.12-slim
RUN useradd -m -u 1000 lumo
WORKDIR /app
COPY --chown=lumo:lumo app.py index.html ./
USER lumo
EXPOSE 8090
CMD ["python3", "-u", "/app/app.py"]
