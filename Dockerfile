###############################################################################
#  Licensed to the Apache Software Foundation (ASF) under one
#  or more contributor license agreements.  See the NOTICE file
#  distributed with this work for additional information
#  regarding copyright ownership.  The ASF licenses this file
#  to you under the Apache License, Version 2.0 (the
#  "License"); you may not use this file except in compliance
#  with the License.  You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
# limitations under the License.
###############################################################################


ARG PY_VER=3.8.12-alpine
ARG BUILD_IMAGE=alpine:3.15.3
ARG JDK_IMAGE=azul/zulu-openjdk-alpine:11.0.15

ARG FLINK_VERSION=flink-1.14.0
ARG FLINK_HOME=/flink
ARG FLINK_SHA512HASH="3798794f00928655d1179a230d3c94f9a9208c65a175d2a0e6517812d8c611bbd16601fcdf446458641d77113f3292b1745a8a577501eb45b99ca97a48e4231c"

ARG PKG_OUT_DIR=/flink/whl
ARG PATCH_DIR=/patch
ARG BUILD_ROOT=/build

ARG JEMALLOC_VERSION=5.2.1


######################################################################
# STAGE: JeMalloc build TODO: move into mvn_builder stage
######################################################################
# hadolint ignore=DL3006
FROM ${BUILD_IMAGE} as builder
ARG JEMALLOC_VERSION

# hadolint ignore=DL3018,DL3003
RUN set -eux; \
    \
    apk add --no-cache \
      sed grep findutils bash zip zstd \
      alpine-sdk \
      libunwind-dev libunwind-static libexecinfo-dev; \
    \
    JEMALLOC_REPO="https://github.com/jemalloc/jemalloc/releases/download/$JEMALLOC_VERSION"; \
    JEMALLLOC_TAR="jemalloc-$JEMALLOC_VERSION.tar.bz2"; \
    wget -qO - "$JEMALLOC_REPO/$JEMALLLOC_TAR" | tar -xj; \
    cd "jemalloc-$JEMALLOC_VERSION"; \
    ./configure \
      --prefix=/usr \
      --sysconfdir=/etc \
      --disable-syscall \
      --enable-prof --enable-prof-libunwind \
      --disable-prof-libgcc --disable-prof-gcc \
      --enable-static=no \
      --enable-shared=yes; \
    make -j"$(nproc)"; \
    # stress and check tests
    # make -j$(nproc) check stress; \
    make install; \
    cd ..


######################################################################
# STAGE: Maven build
######################################################################
FROM python:${PY_VER} AS mvn_builder
ARG FLINK_VERSION
ARG PATCH_DIR
ARG BUILD_ROOT
ARG PKG_OUT_DIR

COPY docker/libsetup.sh /scripts/
COPY docker/APKBUILD-maven /mvn/
# hadolint ignore=DL3018
RUN set -eux; \
    \
    apk add --no-cache \
      patch sed grep coreutils findutils bash zip zstd xz curl rsync jq \
      autoconf automake g++ gfortran git cmake make linux-headers samurai pkgconf \
      go flex bison ccache alpine-sdk libtool utf8proc \
      bsd-compat-headers libtirpc-dev \
      libexecinfo-dev libaio-dev libffi-dev \
      openssl-dev openssl-libs-static apr-dev \
      openblas-dev fftw-dev gmp-dev mpfr-dev \
      openmpi-dev libtbb-dev zlib-dev zstd-dev snappy-dev protobuf-dev; \
    \
    bash -c '. /scripts/libsetup.sh; apk_add_repos; apk_add_repo_azul'; \
    bash -c '. /scripts/libsetup.sh; install_maven /mvn 3.8.5'; \
    apk add --no-cache \
        zulu11-jdk; \
    rm -rf /var/cache/apk/*

# Build Flink
WORKDIR $BUILD_ROOT
COPY docker/install_pkg.sh docker/foreach_requirement.sh /scripts/
COPY packages.json docker/PKBUILD-protoc $BUILD_ROOT/
COPY patch/netty-*.patch patch/protobuf-*.patch $PATCH_DIR/
RUN --mount=type=cache,target=/root/.m2 set -eux; \
    \
    export JAVA_HOME=/usr/lib/jvm/default-jvm; \
    PATCH_DIR=$PATCH_DIR \
    PKG_OUT_DIR=$PKG_OUT_DIR \
    REQUIREMENTS_PROJECT=flink-$FLINK_VERSION \
    REQUIREMENTS_FOREACH=/scripts/install_pkg.sh \
    /scripts/foreach_requirement.sh; \
    echo 'Flink built'

# Build Pyflink
COPY docker/arrow-*.patch $PATCH_DIR/
COPY docker/PKBUILD-pyarrow docker/PKBUILD-pyflink $BUILD_ROOT/
# hadolint ignore=DL3018
RUN --mount=type=cache,target=/root/.m2 \
    --mount=type=cache,target=/root/.cache/pip set -eux; \
    \
    apk add --no-cache \
      libunwind-dev \
      brotli-dev \
      thrift-dev \
      boost-dev; \
    \
    apk fix --reinstall protoc; \
    \
    export JAVA_HOME=/usr/lib/jvm/default-jvm; \
    PATCH_DIR=$PATCH_DIR \
    PKG_OUT_DIR=$PKG_OUT_DIR \
    REQUIREMENTS_PROJECT=pyflink-$FLINK_VERSION \
    REQUIREMENTS_FOREACH=/scripts/install_pkg.sh \
    /scripts/foreach_requirement.sh; \
    echo 'Pyflink built'


######################################################################
# Python wheels image (for reusing in other projects)
######################################################################
# hadolint ignore=DL3006
FROM ${BUILD_IMAGE} as flink_wheels
ARG PKG_OUT_DIR
COPY --from=mvn_builder $PKG_OUT_DIR/*.whl $PKG_OUT_DIR/

RUN --mount=type=cache,target=/root/.cache/pip set -eux; \
    find /root/.cache/ -name '*.whl' -type f \
      -exec cp {} "$PKG_OUT_DIR/" \;


######################################################################
# Final base image (base for snapshot and stable images)
######################################################################
# hadolint ignore=DL3006
FROM ${JDK_IMAGE}-jre as flink_base
ARG FLINK_VERSION
ARG FLINK_HOME
ARG FLINK_SHA512HASH

ENV FLINK_VERSION=$FLINK_VERSION \
    FLINK_HOME=$FLINK_HOME \
    SHA512HASH=$FLINK_SHA512HASH

ENV FLINK_URL_PATH=flink/flink-$FLINK_VERSION/flink-$FLINK_VERSION-bin-scala_2.12.tgz

ENV PATH=$FLINK_HOME/bin:$PATH

USER root

# Jemalloc copy
COPY --from=builder /usr/lib/libjemalloc.so.2 /usr/lib/

# Flink setup
# hadolint ignore=DL3018
RUN set -eux; \
    \
# Install dependencies
    apk add --no-cache \
      patch sed grep coreutils findutils gettext bash zip zstd xz curl rsync jq \
      su-exec \
      libtirpc libstdc++ libgcc \
      libunwind libexecinfo libaio libffi \
      openssl \
      openblas fftw gmp mpfr \
      openmpi libtbb zlib zstd snappy protobuf \
      brotli; \
    \
# User and group creation
    addgroup -g 1001 -S flink; \
    adduser -G flink -u 1001 -s /bin/bash -h $FLINK_HOME -S -D flink;

# Netty tcnative library (TODO: Review if necessary)
# COPY --from=mvn_builder $FLS_TCNATIVE_JAR $FLINK_HOME/lib/
# COPY --from=mvn_builder $FLS_NETTYALL_JAR $FLINK_HOME/lib/

USER flink

# Set the working directory to the Flink home directory
WORKDIR $FLINK_HOME

# Configure container
COPY docker/docker-entrypoint.sh /
ENTRYPOINT ["/docker-entrypoint.sh"]
EXPOSE 6123 8081
CMD ["help"]


######################################################################
# Final Snapshot image
######################################################################
FROM flink_base as flink_snapshot
ARG BUILD_ROOT
ARG FLINK_HOME
ARG FLINK_VERSION

USER root
COPY --from=mvn_builder --chown=flink $BUILD_ROOT/flink/build-target $FLINK_HOME
COPY docker/xmltojson.py /scripts/
COPY docker/copy_maven_package.sh /scripts/copy_maven_package
# hadolint ignore=DL3018
RUN --mount=type=bind,target=/mvn_builder,from=mvn_builder set -eux; \
    apk add --no-cache python3; \
    python3 -m ensurepip --upgrade; \
    python3 -m pip install --no-cache-dir xmltodict==0.12.0; \
    \
    export MVN_PROJECT_ROOT=/mvn_builder$BUILD_ROOT/flink; \
    export PATH="$PATH":/scripts; \
    copy_maven_package flink-formats/flink-sql-avro $FLINK_HOME/opt; \
    copy_maven_package flink-formats/flink-sql-parquet $FLINK_HOME/opt; \
    copy_maven_package flink-connectors/flink-sql-connector-kafka $FLINK_HOME/opt; \
    copy_maven_package flink-formats/flink-sql-avro-confluent-registry $FLINK_HOME/opt; \
    \
    apk del --purge python3; \
    rm -rf /var/cache/apk/*

USER flink


######################################################################
# Final Stable image
######################################################################
FROM flink_base as flink_stable

USER root
RUN set -eux; \
    \
    if [[ "$FLINK_VERSION" != "*SNAPSHOT" ]]; then \
# Download Flink
      curl -fSL -o /tmp/flink.tgz \
        "$(curl --stderr /dev/null \
            https://www.apache.org/dyn/closer.cgi\?as_json=1 \
            | sed -rn 's/.*"preferred":.*"(.*)"/\1/p' \
         )$FLINK_URL_PATH" \
        || curl -fSL -o /tmp/flink.tgz \
        "https://archive.apache.org/dist/$FLINK_URL_PATH"; \
      \
# Verify the contents and then install ...
      echo "$SHA512HASH  /tmp/flink.tgz" | sha512sum -c -; \
      tar -xzf /tmp/flink.tgz -C "$FLINK_HOME" --strip-components 1; \
      rm -f /tmp/flink.tgz; \
# Change ownership
      chown -R flink:flink "$FLINK_HOME"; \
    fi;

USER flink

# Setup connectors jar ...
COPY docker/docker-maven-download.sh /usr/local/bin/docker-maven-download

ENV MAVEN_DEP_DESTINATION=$FLINK_HOME/opt \
    FLC_BASE_MD5=e29b9d2904e4cefa7ab6e9975be8d630 \
    FLC_TAPI_MD5=d95885b97eeebec13f95f73fa81afaee \
    FLC_TPLA_MD5=435b310ab2d49da208c77df24e4b77d9 \
    FLC_STRM_MD5=74a3bf11d468759271a19683ef225abe \
    FLC_TCOM_MD5=179aa7d3604fadd28e2021a39709c0e3 \
    FLC_AVRO_MD5=ec53385fc7d8cca815dc6130104f0ba0 \
    FLC_SAVRO_MD5=9e2a2894b04f590e498fd90563b3870c \
    FLC_CLIENTS_MD5=63cf4c7d9173b6695b94cdd8cb3b132b \
    KFK_CLIENTS_VERSION=3.0.0 \
    KFK_CLIENTS_MD5=8f9e814b615801f50e412859d8490ea7 \
    FLC_JDBC_MD5=8780af9e23c726d588c83f528f6a4bd5 \
    FLC_NIFI_MD5=fefe88d167b5df3db1d03c726e3dffb6 \
    FLC_COMPRESS_MD5=3ce465e7880fe842478fc7979ee3114e \
    FLC_PARQUET_MD5=e5c3910cdb4c0ba0214ff306d4c8b42c \
    FLC_KAFKA_MD5=64b3d312f9c2fdc21e788c1baf57afa9 \
    FLC_SQL_KAFKA_MD5=62cb7bfe2f650430ef1b68fca26af371 \
    FLC_SQL_AVRO_CONFLUENT_REGISTRY_MD5=0e9bfe5e7c7e0da55dc64d6d95934f57 \
    JDBC_PG_VERSION="42.2.14" \
    JDBC_PG_MD5=79869645ab65d5ef28024fc96bb1ce28

RUN set -eux; \
    \
    REPO_PATH=org/apache/flink; \
    REPO_PATH_KAFKA=org/apache/kafka; \
# DataStream connectors
#    docker-maven-download central $REPO_PATH flink-connector-base \
#        "$FLINK_VERSION" "$FLC_BASE_MD5"; \
#    \
    docker-maven-download central "$REPO_PATH_KAFKA" kafka-clients \
        "$KFK_CLIENTS_VERSION" "$KFK_CLIENTS_MD5"; \
    \
    docker-maven-download central "$REPO_PATH" "flink-table-api-scala_$SCALA_VERSION" \
        "$FLINK_VERSION" "$FLC_TAPI_MD5"; \
    \
    docker-maven-download central "$REPO_PATH" "flink-table-planner_$SCALA_VERSION" \
        "$FLINK_VERSION" "$FLC_TPLA_MD5"; \
    \
    docker-maven-download central "$REPO_PATH" "flink-streaming-scala_$SCALA_VERSION" \
        "$FLINK_VERSION" "$FLC_STRM_MD5"; \
    \
    docker-maven-download central "$REPO_PATH" flink-table-common \
        "$FLINK_VERSION" "$FLC_TCOM_MD5"; \
    \
    docker-maven-download central "$REPO_PATH" "flink-connector-jdbc_$SCALA_VERSION" \
        "$FLINK_VERSION" "$FLC_JDBC_MD5"; \
    \
    docker-maven-download central "$REPO_PATH" "flink-connector-kafka_$SCALA_VERSION" \
        "$FLINK_VERSION" "$FLC_KAFKA_MD5"; \
    \
    docker-maven-download central "$REPO_PATH" "flink-connector-nifi_$SCALA_VERSION" \
        "$FLINK_VERSION" "$FLC_NIFI_MD5"; \
    \
# Table API connectors
    docker-maven-download central "$REPO_PATH" "flink-sql-connector-kafka_$SCALA_VERSION" \
        "$FLINK_VERSION" "$FLC_SQL_KAFKA_MD5"; \
    \
    docker-maven-download central "$REPO_PATH" flink-sql-avro-confluent-registry \
        "$FLINK_VERSION" "$FLC_SQL_AVRO_CONFLUENT_REGISTRY_MD5"; \
    \
    docker-maven-download central "$REPO_PATH" flink-sql-avro \
        "$FLINK_VERSION" "$FLC_SAVRO_MD5"; \
# DataSet connectors
    docker-maven-download central "$REPO_PATH" flink-avro \
        "$FLINK_VERSION" "$FLC_AVRO_MD5"; \
    \
# Other libs
    docker-maven-download central "$REPO_PATH" "flink-clients_$SCALA_VERSION" \
        "$FLINK_VERSION" "$FLC_CLIENTS_MD5"; \
    \
    docker-maven-download central "$REPO_PATH" flink-compress \
        "$FLINK_VERSION" "$FLC_COMPRESS_MD5"; \
    \
    docker-maven-download central "$REPO_PATH" "flink-parquet_$SCALA_VERSION" \
        "$FLINK_VERSION" "$FLC_PARQUET_MD5"; \
    \
# JDBC drivers
    docker-maven-download central org/postgresql postgresql \
        "$JDBC_PG_VERSION" "$JDBC_PG_MD5";
