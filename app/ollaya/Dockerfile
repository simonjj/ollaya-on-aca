FROM ghcr.io/ollaya-dev/ollaya:cuda12@sha256:352443b1c49bf77942d2984026a0b7f2824984a25bfddfcd7dcfdc1e182be20a

COPY --chown=1000:1000 app/taxonomy.json /home/ollaya/taxonomy.json
COPY --chown=1000:1000 app/ollaya/Modelfile /home/ollaya/Modelfile
COPY --chown=1000:1000 app/ollaya/start-ollaya.sh /home/ollaya/start-ollaya.sh
RUN chmod 0755 /home/ollaya/start-ollaya.sh

ENTRYPOINT ["/home/ollaya/start-ollaya.sh"]
