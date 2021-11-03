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


ARG JDK_IMAGE=azul/zulu-openjdk-alpine:11.0.13
ARG BUILD_IMAGE=alpine:3.14

ARG FLINK_VERSION=1.14.0
ARG FLINK_SCALA_VERSION=2.12
ARG FLINK_HOME=/flink
ARG FLINK_SHA512HASH="b2895b4f3b905e03a2b394f7da089c70d7148a027fb350de440222e8e0326da9d8a22af8fbcaa705ba6faf81845b6dc3af9ec085325e948447713e86859fc759"
ARG FLINK_MINOR_VERSION=14.0

ARG JEMALLOC_VERSION=5.2.1
ARG TCNATIVE_VERSION=2.0.39.Final
ARG NETTY_VERSION=4.1.65.Final
ARG NETTY_JNI_UTIL_VERSION=0.0.3.Final

ARG FLS_TCNATIVE=flink-shaded-netty-tcnative-static
ARG FLS_NETTYALL=flink-shaded-netty
ARG FLS_PATH=/flink-shaded
ARG FLS_TCNATIVE_JAR=$FLS_PATH/$FLS_TCNATIVE/target/$FLS_TCNATIVE-$TCNATIVE_VERSION-$FLINK_MINOR_VERSION.jar
ARG FLS_NETTYALL_JAR=$FLS_PATH/$FLS_NETTYALL-4/target/$FLS_NETTYALL-$NETTY_VERSION-$FLINK_MINOR_VERSION.jar


FROM ${BUILD_IMAGE} as builder
ARG JEMALLOC_VERSION

RUN set -eux; \
    \
    apk add alpine-sdk libunwind-dev libunwind-static; \
    \
    JEMALLOC_REPO=https://github.com/jemalloc/jemalloc/releases/download/$JEMALLOC_VERSION; \
    JEMALLLOC_TAR=jemalloc-$JEMALLOC_VERSION.tar.bz2; \
    wget -O - $JEMALLOC_REPO/$JEMALLLOC_TAR | tar -xj; \
    cd jemalloc-$JEMALLOC_VERSION; \
    ./configure \
      --prefix=/usr \
      --sysconfdir=/etc \
      --disable-syscall \
      --enable-prof --enable-prof-libunwind \
      --disable-prof-libgcc --disable-prof-gcc \
      --enable-static=no \
      --enable-shared=yes; \
    make -j$(nproc); \
    # stress and check tests
    # make -j$(nproc) check stress; \
    make install; \
    cd ..




FROM ${JDK_IMAGE} as mvn_builder
ARG FLS_PATH
ARG NETTY_VERSION
ARG TCNATIVE_VERSION
ARG NETTY_JNI_UTIL_VERSION
ARG FLINK_VERSION


COPY netty.patch /
RUN set -eux; \
    \
    apk add \
      alpine-sdk libunwind-dev libunwind-static \
      openssl-dev openssl-libs-static libffi-dev apr-dev \
      samurai libtool \
      autoconf automake cmake \
      go \
      maven; \
    \
# Build Netty and Tcnative dependents (jni-util, build-common)
    git clone \
        --depth 1 \
        --branch netty-jni-util-$NETTY_JNI_UTIL_VERSION \
        https://github.com/netty/netty-jni-util.git; \
    cd netty-jni-util; \
    mvn clean install; \
    cd ..; \
    \
# Build Netty (for use in flink-shaded-netty-4)
    git clone \
        --depth 1 \
        --branch netty-$NETTY_VERSION \
        https://github.com/netty/netty.git; \
    cd netty; \
    patch -p1 < /netty.patch; \
    mvn clean install -DskipTests; \
    mvn clean install -pl all -Puber-snapshot; \
    cd ..; \
    \
# Build Tcnative as uber jar
    git clone \
        --depth 1 \
        --branch netty-tcnative-parent-$TCNATIVE_VERSION \
        https://github.com/netty/netty-tcnative.git; \
    cd netty-tcnative; \
    for profile in "boringssl-static-default" "uber-snapshot"; do \
      mvn clean install -P$profile -pl boringssl-static; \
    done; \
    cd ..; \
    \
# Build Flink shaded for Netty ant Tcnative
    FLINK_MINOR_VERSION=$(echo $FLINK_VERSION | cut -d '.' -f 2,3); \
    git clone \
        --depth 1 \
        --branch release-$FLINK_MINOR_VERSION \
        https://github.com/apache/flink-shaded.git $FLS_PATH; \
    cd $FLS_PATH; \
    for module in "netty-4" "netty-tcnative-static"; do \
      mvn clean package \
          -Pinclude-netty-tcnative-static \
          -pl flink-shaded-$module; \
    done; \
    cd ..; \
    echo 'Flink Shaded Jars built!'




FROM ${JDK_IMAGE}-jre as flink_base
ARG FLINK_VERSION
ARG FLINK_MINOR_VERSION
ARG FLINK_SCALA_VERSION
ARG FLINK_HOME
ARG FLINK_SHA512HASH
ARG FLS_TCNATIVE_JAR
ARG FLS_NETTYALL_JAR
ARG TCNATIVE_VERSION

ENV FLINK_VERSION=$FLINK_VERSION \
    SCALA_VERSION=$FLINK_SCALA_VERSION \
    FLINK_HOME=$FLINK_HOME \
    SHA512HASH=$FLINK_SHA512HASH

ENV FLINK_URL_PATH=flink/flink-$FLINK_VERSION/flink-$FLINK_VERSION-bin-scala_$SCALA_VERSION.tgz

ENV PATH=$FLINK_HOME/bin:$PATH

USER root

# Jemalloc copy
COPY --from=builder /usr/lib/libjemalloc.so.2 /usr/lib/

# Flink setup
#
RUN set -eux; \
    \
# Install dependencies
    apk add --no-cache --upgrade curl bash su-exec \
      libstdc++ libgcc libunwind \
      openssl \
      snappy-dev \
      gettext-dev; \
    \
# User and group creation
    addgroup -g 1001 -S flink; \
    adduser -G flink -u 1001 -s /bin/bash -h $FLINK_HOME -S -D flink; \
    \
# Download Flink
    curl -fSL -o /tmp/flink.tgz \
      $(curl --stderr /dev/null \
          https://www.apache.org/dyn/closer.cgi\?as_json\=1 \
          | sed -rn 's/.*"preferred":.*"(.*)"/\1/p' \
       )$FLINK_URL_PATH \
      || curl -fSL -o /tmp/flink.tgz \
      https://archive.apache.org/dist/$FLINK_URL_PATH; \
    \
# Verify the contents and then install ...
    echo "$SHA512HASH  /tmp/flink.tgz" | sha512sum -c -; \
    tar -xzf /tmp/flink.tgz -C $FLINK_HOME --strip-components 1; \
    rm -f /tmp/flink.tgz; \
    \
# Change ownership
    chown -R flink $FLINK_HOME; \
    chgrp -R flink $FLINK_HOME

# Netty tcnative library
COPY --from=mvn_builder $FLS_TCNATIVE_JAR /$FLINK_HOME/lib/
COPY --from=mvn_builder $FLS_NETTYALL_JAR /$FLINK_HOME/lib/

USER flink

# Set the working directory to the Flink home directory
WORKDIR $FLINK_HOME

# Configure container
COPY docker-entrypoint.sh /
ENTRYPOINT ["/docker-entrypoint.sh"]
EXPOSE 6123 8081
CMD ["help"]




FROM flink_base as flink

COPY docker-maven-download.sh /usr/local/bin/docker-maven-download

# Setup connectors jar ...
ENV MAVEN_DEP_DESTINATION=$FLINK_HOME/opt \
    FLC_BASE_MD5=e29b9d2904e4cefa7ab6e9975be8d630 \
    FLC_TAPI_MD5=d95885b97eeebec13f95f73fa81afaee \
    FLC_TPLA_MD5=435b310ab2d49da208c77df24e4b77d9 \
    FLC_STRM_MD5=74a3bf11d468759271a19683ef225abe \
    FLC_TCOM_MD5=179aa7d3604fadd28e2021a39709c0e3 \
    FLC_AVRO_MD5=ec53385fc7d8cca815dc6130104f0ba0 \
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
    docker-maven-download central $REPO_PATH_KAFKA kafka-clients \
        "$KFK_CLIENTS_VERSION" "$KFK_CLIENTS_MD5"; \
    \
    docker-maven-download central $REPO_PATH flink-table-api-scala_$SCALA_VERSION \
        "$FLINK_VERSION" "$FLC_TAPI_MD5"; \
    \
    docker-maven-download central $REPO_PATH flink-table-planner_$SCALA_VERSION \
        "$FLINK_VERSION" "$FLC_TPLA_MD5"; \
    \
    docker-maven-download central $REPO_PATH flink-streaming-scala_$SCALA_VERSION \
        "$FLINK_VERSION" "$FLC_STRM_MD5"; \
    \
    docker-maven-download central $REPO_PATH flink-table-common \
        "$FLINK_VERSION" "$FLC_TCOM_MD5"; \
    \
    docker-maven-download central $REPO_PATH flink-connector-jdbc_$SCALA_VERSION \
        "$FLINK_VERSION" "$FLC_JDBC_MD5"; \
    \
    docker-maven-download central $REPO_PATH flink-connector-kafka_$SCALA_VERSION \
        "$FLINK_VERSION" "$FLC_KAFKA_MD5"; \
    \
    docker-maven-download central $REPO_PATH flink-connector-nifi_$SCALA_VERSION \
        "$FLINK_VERSION" "$FLC_NIFI_MD5"; \
    \
# Table API connectors
    docker-maven-download central $REPO_PATH flink-sql-connector-kafka_$SCALA_VERSION \
        "$FLINK_VERSION" "$FLC_SQL_KAFKA_MD5"; \
    \
    docker-maven-download central $REPO_PATH flink-sql-avro-confluent-registry \
        "$FLINK_VERSION" "$FLC_SQL_AVRO_CONFLUENT_REGISTRY_MD5"; \
    \
# DataSet connectors
    docker-maven-download central $REPO_PATH flink-avro \
        "$FLINK_VERSION" "$FLC_AVRO_MD5"; \
    \
# Other libs
    docker-maven-download central $REPO_PATH flink-clients_$SCALA_VERSION \
        "$FLINK_VERSION" "$FLC_CLIENTS_MD5"; \
    \
    docker-maven-download central $REPO_PATH flink-compress \
        "$FLINK_VERSION" "$FLC_COMPRESS_MD5"; \
    \
    docker-maven-download central $REPO_PATH flink-parquet_$SCALA_VERSION \
        "$FLINK_VERSION" "$FLC_PARQUET_MD5"; \
    \
# JDBC drivers
    docker-maven-download central org/postgresql postgresql \
        "$JDBC_PG_VERSION" "$JDBC_PG_MD5"
