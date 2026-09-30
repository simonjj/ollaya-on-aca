FROM ghcr.io/ollaya-dev/ollaya:0.7.5

COPY --chown=1000:1000 Modelfile questions.json /home/ollaya/
COPY --chown=1000:1000 start-ollaya.sh /home/ollaya/start-ollaya.sh
RUN chmod 0755 /home/ollaya/start-ollaya.sh

ENTRYPOINT ["/home/ollaya/start-ollaya.sh"]
