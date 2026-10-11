# lab-media-auth — bibliothèque standard seule, aucune dépendance à installer.
# Image de base épinglée par digest (celle déjà présente sur l'hôte).
FROM python:3.12-slim@sha256:02108f5d322dd89f1c9e552442c25acb0543dfdbc455693a5599624f20d9155d

ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin labmedia \
 && mkdir /config && chown 10001:10001 /config
COPY labmediaauth /opt/lab-media/labmediaauth
COPY mediamtx.base.yml /opt/lab-media/mediamtx.base.yml
COPY tests /opt/lab-media/tests
WORKDIR /opt/lab-media
USER 10001
HEALTHCHECK --interval=10s --timeout=3s --start-period=3s --retries=3 \
  CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:9100/healthz', timeout=2).status == 200 else 1)"]
CMD ["python", "-m", "labmediaauth"]
