ARG GO_VERSION=1.26.0
FROM golang:${GO_VERSION}-alpine AS build

# Update libraries
RUN apk update && apk upgrade

# Set workdir
WORKDIR /go/src

# Build go package
ADD . /go/src/clamav-rest/
RUN cd /go/src/clamav-rest && go mod tidy && go build -v

FROM alpine:3.23

# Copy compiled clamav-rest binary from build container to production container
COPY --from=build /go/src/clamav-rest/clamav-rest /usr/bin/

# Update & Install tzdata
RUN apk update && apk upgrade && apk add --no-cache tzdata

# Enable Bash & logrotate
RUN apk add bash logrotate

COPY clamavlogrotate /etc/logrotate.d/clamav

# Set timezone to UTC so log timestamps correlate with external systems
ENV TZ=Etc/UTC

# Create SSL directory for runtime-mounted certificates
RUN mkdir -p /etc/ssl/clamav-rest

# Install ClamAV
RUN apk --no-cache add clamav clamav-libunrar \
    && mkdir /run/clamav \
    && chown clamav:clamav /run/clamav 


# Configure clamAV to run in foreground with port 3310
RUN sed -i 's/^#Foreground .*$/Foreground yes/g' /etc/clamav/clamd.conf \
    && sed -i 's/^#TCPSocket .*$/TCPSocket 3310/g' /etc/clamav/clamd.conf \
    && sed -i 's/^#Foreground .*$/Foreground yes/g' /etc/clamav/freshclam.conf

# Download virus signatures at build time so the image ships ready to scan
# (runtime freshclam is disabled by default for airgapped use). FRESHCLAM_DATE
# is supplied by the release workflow as the current date; referencing it here
# busts this layer's build cache once per day, so the scheduled rebuild fetches
# fresh definitions instead of reusing a stale cached layer.
ARG FRESHCLAM_DATE=unknown
RUN echo "Signatures fetched for: ${FRESHCLAM_DATE}" && freshclam --quiet --no-dns

COPY entrypoint.sh /usr/bin/

RUN mkdir -p /clamav/etc \
    && mkdir -p /clamav/data \
    && mkdir -p /clamav/tmp 

RUN chown -R clamav:clamav /clamav \
    && chown -R clamav:clamav /var/log/clamav \
    && chown -R clamav:clamav /run/clamav 


ENV PORT=9000
ENV SSL_PORT=9443
ENV MAX_SCAN_SIZE=100M
ENV MAX_FILE_SIZE=25M
ENV MAX_RECURSION=16
ENV MAX_FILES=10000
ENV MAX_EMBEDDEDPE=10M
ENV MAX_HTMLNORMALIZE=10M
ENV MAX_HTMLNOTAGS=2M
ENV MAX_SCRIPTNORMALIZE=5M
ENV MAX_ZIPTYPERCG=1M
ENV MAX_PARTITIONS=50
ENV MAX_ICONSPE=100
ENV MAX_RECONNECT_TIME=30
ENV PCRE_MATCHLIMIT=100000
ENV PCRE_RECMATCHLIMIT=2000
ENV SIGNATURE_CHECKS=2
ENV ALLOW_ORIGINS=*
ENV DISABLE_FRESHCLAM=true

USER clamav

ENTRYPOINT [ "entrypoint.sh" ]
