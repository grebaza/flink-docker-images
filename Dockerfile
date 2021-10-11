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

FROM azul/zulu-openjdk-alpine:11.0.11-jre

ENV FLINK_VERSION=1.14.0 \
    SCALA_VERSION=2.12 \
    FLINK_HOME=/flink \
    SHA512HASH="b2895b4f3b905e03a2b394f7da089c70d7148a027fb350de440222e8e0326da9d8a22af8fbcaa705ba6faf81845b6dc3af9ec085325e948447713e86859fc759"

ENV FLINK_URL_PATH=flink/flink-$FLINK_VERSION/flink-$FLINK_VERSION-bin-scala_$SCALA_VERSION.tgz

ENV PATH=$FLINK_HOME/bin:$PATH

USER root

# Flink setup
#
RUN set -eux; \
    \
# Install dependencies
    apk add --no-cache --upgrade curl bash su-exec \
      snappy-dev \
      gettext-dev; \
    \
# User and group creation
    addgroup -g 1001 -S flink; \
    adduser -G flink -u 1001 -s /bin/bash -h $FLINK_HOME -S -D flink; \
# Download Flink
    curl -fSL -o /tmp/flink.tgz \
      $(curl --stderr /dev/null \
          https://www.apache.org/dyn/closer.cgi\?as_json\=1 \
          | sed -rn 's/.*"preferred":.*"(.*)"/\1/p' \
       )$FLINK_URL_PATH \
      || curl -fSL -o /tmp/flink.tgz \
      https://archive.apache.org/dist/$FLINK_URL_PATH; \
# Verify the contents and then install ...
    echo "$SHA512HASH  /tmp/flink.tgz" | sha512sum -c -; \
    tar -xzf /tmp/flink.tgz -C $FLINK_HOME --strip-components 1; \
    rm -f /tmp/flink.tgz; \
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
