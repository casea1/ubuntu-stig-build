FROM ghcr.io/open-webui/oikb:0.3.6

RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/* 

WORKDIR /tmp

RUN git clone https://github.com/open-webui/oikb.git

RUN sed -i 's/files = info\.get("files", \[\])/files = client.list_kb_files(kb)/' /tmp/oikb/src/oikb/cli.py && \
    sed -i 's/file_count = len(kb\.get("files", \[\]))/file_count = len(client.list_kb_files(kb_id))/' /tmp/oikb/src/oikb/cli.py && \
    sed -i 's|resp = self\._http\.get(f"/knowledge/{kb_id}")|resp = self._http.get(f"/knowledge/{kb_id}/files")|' /tmp/oikb/src/oikb/client.py && \
    sed -i 's/return data\.get("files", \[\])/return data.get("items", [])/' /tmp/oikb/src/oikb/client.py

RUN pip install --no-cache-dir uv-build && \
    pip install --force-reinstall --no-deps --no-index --no-build-isolation /tmp/oikb/.

WORKDIR /app