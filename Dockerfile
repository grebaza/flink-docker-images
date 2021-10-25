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

FROM alpine:3.13 as builder

RUN set -eux; \
    \
    apk add build-base libunwind-dev libunwind-static; \
    \
    wget -O - https://github.com/jemalloc/jemalloc/releases/download/5.2.1/jemalloc-5.2.1.tar.bz2 \
      | tar -xj; \
    cd jemalloc-5.2.1; \
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
    make install


FROM azul/zulu-openjdk-alpine:11.0.11-jre as flink_base

ENV FLINK_VERSION=1.14.0 \
    SCALA_VERSION=2.12 \
    FLINK_HOME=/flink \
    SHA512HASH="b2895b4f3b905e03a2b394f7da089c70d7148a027fb350de440222e8e0326da9d8a22af8fbcaa705ba6faf81845b6dc3af9ec085325e948447713e86859fc759"

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
    FLC_AVRO_MD5=ec53385fc7d8cca815dc6130104f0ba0 \
    FLC_CLIENTS_MD5=63cf4c7d9173b6695b94cdd8cb3b132b \
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
# DataStream connectors
    docker-maven-download central $REPO_PATH flink-connector-base \
        "$FLINK_VERSION" "$FLC_BASE_MD5"; \
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
