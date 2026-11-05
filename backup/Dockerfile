FROM alpine:3.20
RUN apk add --no-cache bash age rclone mongodb-tools \
 && adduser -D -u 1000 backup
COPY --chmod=755 backup.sh restore.sh run-scheduled.sh /usr/local/bin/
USER backup
CMD ["run-scheduled.sh"]
