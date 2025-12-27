FROM docker:27-cli

RUN apk add --no-cache bash curl jq coreutils logrotate

COPY crontab /etc/crontabs/root
COPY rotate-next.sh /usr/local/bin/rotate-next.sh
COPY sync-chain.sh  /usr/local/bin/sync-chain.sh
COPY logrotate-warp-rotator /etc/logrotate.d/warp-rotator

RUN chmod +x /usr/local/bin/rotate-next.sh /usr/local/bin/sync-chain.sh \
 && mkdir -p /var/lib/warp-rotator /var/log

CMD ["crond", "-f", "-l", "8"]

