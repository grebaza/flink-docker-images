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
ARG BUILD_IMAGE=alpine:3.15.3

ARG FLINK_VERSION=1.14.3
ARG FLINK_SCALA_VERSION=2.12
ARG FLINK_HOME=/flink
ARG FLINK_SHA512HASH="3798794f00928655d1179a230d3c94f9a9208c65a175d2a0e6517812d8c611bbd16601fcdf446458641d77113f3292b1745a8a577501eb45b99ca97a48e4231c"
ARG FLINK_MINOR_VERSION=14.3
ARG FLINK_COMMIT=

ARG JEMALLOC_VERSION=5.2.1
ARG TCNATIVE_VERSION=2.0.39.Final
ARG NETTY_VERSION=4.1.65.Final
ARG NETTY_JNI_UTIL_VERSION=0.0.3.Final
ARG FLINK_SHADED_VERSION=14.0

ARG FLS_TCNATIVE=flink-shaded-netty-tcnative-static
ARG FLS_NETTYALL=flink-shaded-netty
ARG FLS_PATH=/flink-shaded
ARG FLS_TCNATIVE_JAR=$FLS_PATH/$FLS_TCNATIVE/target/$FLS_TCNATIVE-$TCNATIVE_VERSION-$FLINK_SHADED_VERSION.jar
ARG FLS_NETTYALL_JAR=$FLS_PATH/$FLS_NETTYALL-4/target/$FLS_NETTYALL-$NETTY_VERSION-$FLINK_SHADED_VERSION.jar

ARG PKG_BIN_DIR=/flink/whl

######################################################################
# STAGE: JeMalloc build
######################################################################
FROM ${BUILD_IMAGE} as builder
ARG JEMALLOC_VERSION

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
    make -j$(nproc); \
    # stress and check tests
    # make -j$(nproc) check stress; \
    make install; \
    cd ..


######################################################################
# STAGE: Maven build
######################################################################
FROM ${JDK_IMAGE} as mvn_builder
ARG FLS_PATH
ARG NETTY_VERSION
ARG TCNATIVE_VERSION
ARG NETTY_JNI_UTIL_VERSION
ARG FLINK_SHADED_VERSION
ARG FLINK_VERSION
ARG FLINK_SCALA_VERSION
ARG FLINK_COMMIT


RUN set -eux; \
    \
    apk add --no-cache \
      sed grep findutils bash zip unzip zstd snappy-dev \
      xz ccache utf8proc \
      autoconf automake g++ gfortran git cmake make linux-headers samurai pkgconf \
      alpine-sdk libtool \
      libunwind-dev libunwind-static libexecinfo-dev \
      openssl-dev openssl-libs-static libffi-dev apr-dev \
      openblas-dev fftw-dev gmp-dev mpfr-dev \
      openmpi-dev libtbb-dev zlib-dev zstd-dev \
      go \
      maven

# Build Flink's dependencies
COPY netty-*.patch /
RUN --mount=type=cache,target=/root/.m2 set -eux; \
    \
# Build Netty and Tcnative dependents (jni-util, build-common)
    git clone \
        --depth 1 \
        --branch "netty-jni-util-$NETTY_JNI_UTIL_VERSION" \
        -c advice.detachedHead=false \
        https://github.com/netty/netty-jni-util.git; \
    cd netty-jni-util; \
    mvn clean install; \
    cd ..; \
    \
# Build Netty (for use in flink-shaded-netty-4)
    git clone \
        --depth 1 \
        --branch "netty-$NETTY_VERSION" \
        -c advice.detachedHead=false \
        https://github.com/netty/netty.git; \
    cd netty; \
    patch -p1 < "/netty-$NETTY_VERSION.patch"; \
    . build-vars.sh; \
    mvn -am -pl transport-native-unix-common,transport-native-kqueue,transport-native-epoll \
        clean install -DskipTests=true; \
    mvn -P"full,$NETTY_NATIVE_PROFILE" -pl all clean install; \
    cd ..; \
    \
# Build Tcnative as uber jar
    git clone \
        --depth 1 \
        --branch "netty-tcnative-parent-$TCNATIVE_VERSION" \
        -c advice.detachedHead=false \
        https://github.com/netty/netty-tcnative.git; \
    cd netty-tcnative; \
    for profile in "boringssl-static-default" "uber-snapshot"; do \
      mvn clean install -P"$profile" -pl boringssl-static; \
    done; \
    cd ..; \
    \
# Build Flink shaded for Netty ant Tcnative
    git clone \
        --depth 1 \
        --branch "release-$FLINK_SHADED_VERSION" \
        -c advice.detachedHead=false \
        https://github.com/apache/flink-shaded.git "$FLS_PATH"; \
    cd "$FLS_PATH"; \
    for module in "netty-4" "netty-tcnative-static"; do \
      mvn clean install \
          -Pinclude-netty-tcnative-static \
          -pl "flink-shaded-$module"; \
    done; \
    cd ..; \
    echo 'Flink Shaded Jars built!'

# Build Flink (if SNAPSHOT version)
COPY flink-*.patch /
COPY protobuf-*.patch /
RUN --mount=type=cache,target=/root/.m2 set -eux; \
    \
    if [[ "$FLINK_VERSION" == "*SNAPSHOT*" ]]; then \
      git clone \
          https://github.com/apache/flink.git; \
      cd flink; \
      [[ "$FLINK_COMMIT" ]] && git checkout "$FLINK_COMMIT" || true; \
      patch -p1 < "/flink-$FLINK_VERSION.patch"; \
      . build-vars.sh; cd ..; \
      \
      git clone --depth 1 --branch "v$PROTOBUF_VERSION" \
          -c advice.detachedHead=false \
          https://github.com/google/protobuf.git; \
      cd protobuf; \
      patch -p1 < "/protobuf-$PROTOBUF_VERSION.patch"; \
      ./autogen.sh; cd protoc-artifacts && mvn install; \
      . build-vars.sh; cp "$PROTOBUF_FILE" /usr/bin/protoc; \
      cd ../../flink; \
      \
      mvn clean package -D"scala-$FLINK_SCALA_VERSION" -DskipTests \
          -DprotocCommand=/usr/bin/protoc \
          -DprotocExecutable=/usr/bin/protoc; \
      cd ..; \
      echo 'Flink built!'; \
    fi;

# Build pyflink
COPY docker/arrow-*.patch /scripts/
COPY docker/build_pyarrow.sh docker/libsetup.sh /scripts/
RUN --mount=type=cache,target=/root/.m2 \
    --mount=type=cache,target=/root/.cache/pip set -eux; \
    \
    apk add --no-cache \
      --repository=http://dl-cdn.alpinelinux.org/alpine/v3.13/main \
      python3=3.8.10-r0 python3-dev=3.8.10-r0; \
    apk add --no-cache \
      --repository=http://dl-cdn.alpinelinux.org/alpine/v3.13/main \
      boost-dev=1.72.0-r6 \
      boost-libs=1.72.0-r6 \
      boost-chrono=1.72.0-r6 \
      boost-container=1.72.0-r6 \
      boost-context=1.72.0-r6 \
      boost-contract=1.72.0-r6 \
      boost-coroutine=1.72.0-r6 \
      boost-date_time=1.72.0-r6 boost-fiber=1.72.0-r6 \
      boost-filesystem=1.72.0-r6 \
      boost-graph=1.72.0-r6 \
      boost-iostreams=1.72.0-r6 boost-locale=1.72.0-r6 \
      boost-log=1.72.0-r6 boost-log_setup=1.72.0-r6 \
      boost-math=1.72.0-r6 boost-prg_exec_monitor=1.72.0-r6 \
      boost-program_options=1.72.0-r6 boost-python3=1.72.0-r6 \
      boost-random=1.72.0-r6 boost-regex=1.72.0-r6 \
      boost-serialization=1.72.0-r6 boost-stacktrace_basic=1.72.0-r6 \
      boost-stacktrace_noop=1.72.0-r6 boost-system=1.72.0-r6 \
      boost-thread=1.72.0-r6 boost-timer=1.72.0-r6 \
      boost-type_erasure=1.72.0-r6 boost-unit_test_framework=1.72.0-r6 \
      boost-wave=1.72.0-r6 boost-wserialization=1.72.0-r6 \
      boost-atomic=1.72.0-r6 \
      boost=1.72.0-r6; \
    \
    python3 -m ensurepip --upgrade; \
    pip3 --no-cache-dir install -U pip setuptools wheel cython; \
    \
    pip3 install numpy==1.19.5; \
    \
    export PIP_FIND_LINKS="/tmp"; \
    ARROW_VERSION=2.0.0 \
    NUMPY_VERSION=1.19.5 \
    NO_INSTALL_BUILD_TOOLS=true \
    ARROW_VERBOSE_THIRDPARTY_BUILD=ON \
    WHEEL_DIR="$PIP_FIND_LINKS" \
    scripts/build_pyarrow.sh; \
    \
    cd flink/flink-python; \
    CXXFLAGS="-O2 -g0" CMAKE_GENERATOR=Ninja NPY_DISTUTILS_APPEND_FLAGS=1 \
    pip3 install -r dev/dev-requirements.txt; \
    pip3 install build; \
    python3 -m build --wheel -o /tmp; \
    cd apache-flink-libraries; \
    python3 -m build --wheel --sdist -o /tmp; \
    \
    mkdir -p /flink-whl; \
    mv /tmp/*.whl /flink-whl; \
    find "$HOME/.cache/" -name '*.whl' -type f \
      -exec mv {} "/flink-whl" \;


######################################################################
# Python wheels image
######################################################################
FROM ${BUILD_IMAGE} as flink_wheels
ARG PKG_BIN_DIR
COPY --from=mvn_builder /flink-whl/*.whl $PKG_BIN_DIR/


######################################################################
# Final base image (base for snapshot and stable images)
######################################################################
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
RUN set -eux; \
    \
# Install dependencies
    apk add --no-cache \
      sed grep findutils gettext bash zlib zip zstd snappy \
      curl su-exec \
      libstdc++ libgcc libunwind libexecinfo \
      openblas fftw gmp mpfr \
      openssl libffi \
      openmpi libtbb; \
    \
# User and group creation
    addgroup -g 1001 -S flink; \
    adduser -G flink -u 1001 -s /bin/bash -h $FLINK_HOME -S -D flink;

# Netty tcnative library
COPY --from=mvn_builder $FLS_TCNATIVE_JAR $FLINK_HOME/lib/
COPY --from=mvn_builder $FLS_NETTYALL_JAR $FLINK_HOME/lib/

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

COPY --from=mvn_builder --chown=flink /flink/build-target $FLINK_HOME
COPY --from=mvn_builder /flink/flink-connectors/flink-connector-jdbc/target/flink-connector-jdbc-1.15.0.jar /flink/opt
COPY --from=mvn_builder /flink/flink-connectors/flink-sql-connector-kafka/target/flink-sql-connector-kafka-1.15.0.jar /flink/opt
COPY --from=mvn_builder /flink/flink-formats/flink-sql-avro/target/flink-sql-avro-1.15.0.jar /flink/opt
COPY --from=mvn_builder /flink/flink-formats/flink-sql-parquet/target/flink-sql-parquet-1.15.0.jar /flink/opt
COPY --from=mvn_builder /flink/flink-formats/flink-sql-avro-confluent-registry/target/flink-sql-avro-confluent-registry-1.15.0.jar /flink/opt


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
