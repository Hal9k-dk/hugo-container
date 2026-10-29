FROM golang:1.27-alpine AS go-toolchain

# Build against the same musl/libstdc++ as the runtime image.
FROM alpine:3.22 AS hugo-build
COPY --from=go-toolchain /usr/local/go /usr/local/go
ENV PATH="/usr/local/go/bin:${PATH}" \
    GOPATH=/go \
    CGO_ENABLED=1
ARG HUGO_VERSION=0.169.0
RUN apk add --no-cache ca-certificates git gcc g++ musl-dev \
    && go install -tags extended,withdeploy github.com/gohugoio/hugo@v${HUGO_VERSION}

FROM alpine:3.22

COPY --from=hugo-build /go/bin/hugo /usr/local/bin/hugo
RUN apk add --no-cache \
      bash ca-certificates coreutils findutils git git-lfs libstdc++ nginx openssh-server \
      openssh-client su-exec tzdata util-linux \
    && adduser -D -h /home/deploy -s /bin/bash deploy \
    && passwd -d deploy \
    && mkdir -p /etc/ssh/authorized_keys /run/nginx /data \
    && git lfs install --system

COPY nginx.conf /etc/nginx/nginx.conf
COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh deploy-site /usr/local/bin/
RUN chmod 755 /usr/local/bin/entrypoint.sh /usr/local/bin/deploy-site

ENV BRANCH=main \
    HUGO_ENVIRONMENT=production

EXPOSE 80 2222
VOLUME ["/data"]
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
