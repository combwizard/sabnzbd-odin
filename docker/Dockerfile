FROM python:3.12-slim-bookworm

ARG UNRAR_VERSION=7.0.9
ARG PUID=1000
ARG PGID=1000

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        par2 \
        p7zip-full \
    && mkdir /tmp/unrar \
    && curl -fsSL "https://www.rarlab.com/rar/unrarsrc-${UNRAR_VERSION}.tar.gz" \
        | tar xz -C /tmp/unrar --strip-components=1 \
    && make -C /tmp/unrar \
    && install -m755 /tmp/unrar/unrar /usr/local/bin/unrar \
    && rm -rf /tmp/unrar \
    && apt-get purge -y build-essential curl \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# Match host pool ownership (smith / 1000:1000). Compose PUID/PGID must stay aligned.
RUN groupadd -g "${PGID}" odin \
    && useradd -u "${PUID}" -g odin -M -d /app odin

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .
RUN chown -R odin:odin /app

ENV SABNZBD_INI=/opt/_dockers/sabnzbd-odin/config/sabnzbd.ini

USER odin

EXPOSE 8383

CMD ["python", "-OO", "SABnzbd.py", "-f", "/opt/_dockers/sabnzbd-odin/config/sabnzbd.ini", "-s", "0.0.0.0:8383", "-b", "0"]
