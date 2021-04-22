ARG ALPINE_VERSION=3.13
ARG RUBY_VERSION=2.7.3
ARG NODE_VERSION=14.16.1
ARG JEMALLOC_VERSION=5.2.1
ARG LIBICONV_VERSION=1.16

ARG UID=991
ARG GID=991


# Build Mastodon stack base (Ruby + Node)
FROM node:${NODE_VERSION}-alpine${ALPINE_VERSION} as node
FROM ruby:${RUBY_VERSION}-alpine${ALPINE_VERSION} as node-ruby
COPY --from=node /usr/local /usr/local
COPY --from=node /opt /opt


# Build Jemalloc
FROM alpine:${ALPINE_VERSION} as build-jemalloc

ARG JEMALLOC_VERSION

RUN apk --no-cache add build-base && cd /tmp \
 && wget -q https://github.com/jemalloc/jemalloc/releases/download/${JEMALLOC_VERSION}/jemalloc-${JEMALLOC_VERSION}.tar.bz2 \
 && mkdir jemalloc && tar xf jemalloc-${JEMALLOC_VERSION}.tar.bz2 -C jemalloc --strip-components 1 \
 && cd jemalloc && ./configure && make -j$(getconf _NPROCESSORS_ONLN) && make install


# Build GNU Libiconv (best support for nokogiri)
FROM alpine:${ALPINE_VERSION} as build-gnulibiconv

ARG LIBICONV_VERSION

RUN apk --no-cache add build-base \
 && wget -q https://ftp.gnu.org/pub/gnu/libiconv/libiconv-${LIBICONV_VERSION}.tar.gz \
 && mkdir /tmp/libiconv && tar xf libiconv-${LIBICONV_VERSION}.tar.gz -C /tmp/libiconv --strip-components 1 \
 && cd /tmp/libiconv && mkdir output && ./configure --prefix=$PWD/output \
 && make -j$(getconf _NPROCESSORS_ONLN) && make install


# Build Mastodon
FROM node-ruby as build-mastodon

RUN apk --no-cache add \
    build-base \
    icu-dev \
    imagemagick \
    libidn-dev \
    libtool \
    libxml2-dev \
    libxslt-dev \
    postgresql-dev \
    protobuf-dev \
    python3

COPY Gemfile* package.json yarn.lock /mastodon/

RUN cd /mastodon \
 && bundle config build.nokogiri --use-system-libraries --with-iconv-lib=/usr/local/lib --with-iconv-include=/usr/local/include \
 && bundle config set --local clean 'true' && bundle config set --local deployment 'true' \
 && bundle config set --local without 'test development' && bundle config set no-cache 'true' \
 && bundle install -j$(getconf _NPROCESSORS_ONLN) \
 && yarn install --pure-lockfile --ignore-engines


# Prepare production environment
FROM node-ruby as production

COPY --from=build-mastodon /usr/local /usr/local
COPY --from=build-gnulibiconv /tmp/libiconv/output /usr/local
COPY --from=build-jemalloc /usr/local/lib/libjemalloc.so.2 /usr/local/lib/

ARG UID
ARG GID

ENV BIND=0.0.0.0 \
    RAILS_SERVE_STATIC_FILES=true \
    RAILS_ENV=production \
    NODE_ENV=production \
    PATH="${PATH}:/mastodon/bin" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so.2"

RUN apk --no-cache add \
    ca-certificates \
    ffmpeg \
    file \
    gcompat \
    git \
    icu-libs \
    imagemagick \
    libidn \
    libpq \
    libxml2 \
    libxslt \
    openssl \
    protobuf \
    readline \
    s6 \
    tini \
    tzdata \
    yaml \
 && adduser -g ${GID} -u ${UID} --disabled-password --gecos "" mastodon

COPY --chown=mastodon:mastodon . /mastodon
COPY --from=build-mastodon --chown=mastodon:mastodon /mastodon /mastodon

USER mastodon

WORKDIR /mastodon

# Precompile assets
RUN OTP_SECRET=precompile_placeholder SECRET_KEY_BASE=precompile_placeholder rails assets:precompile \
 && yarn cache clean

# Set work dir, entrypoint & ports
EXPOSE 3000 4000

ENTRYPOINT ["/sbin/tini", "--"]
