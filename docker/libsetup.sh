#!/usr/bin/env bash
#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

set -e

pip_upgrade() {
  pip3 install \
    --no-cache-dir \
    --upgrade pip setuptools wheel cython
}

lineinfile() {
  if [ $# -ne 3 ]; then
    local THIS_FUNC_NAME="${funcstack[1]-}${FUNCNAME[0]-}"
    echo "$THIS_FUNC_NAME - 3 arguments are expected. given $#. args=[$*]" >&2
    echo "usage: $THIS_FUNC_NAME PATTERN LINE FILE" >&2
    return 1
  fi
  local PATTERN="${1//\//\\/}" #sed-escaping of slash char
  local LINE="${2//\//\\/}"
  local FILE="$3"
  # Sed solution on https://stackoverflow.com/a/29060802
  # shellcheck disable=SC2016
  if ! sed -i "/$PATTERN/{s//$LINE/;h};"'${x;/./{x;q0};x;q1}' "$FILE" ;then
    echo "$2" >> "$3"
  fi
}

apk_add_repos() {
  local FILE='/etc/apk/repositories'
  # append lines
  lineinfile '^@edge_main .*$' '@edge_main http://dl-cdn.alpinelinux.org/alpine/edge/main' "$FILE"
  lineinfile '^@edge_comm .*$' '@edge_comm http://dl-cdn.alpinelinux.org/alpine/edge/community' "$FILE"
  lineinfile '^@edge_test .*$' '@edge_test http://dl-cdn.alpinelinux.org/alpine/edge/testing' "$FILE"
}

toolchain_install() {
  # Install build tools
  apk add --no-cache --update \
    g++ git unzip cmake make linux-headers \
    flex bison \
    curl \
    samurai \
    patch \
    pkgconf \
    cyrus-sasl-dev \
    libexecinfo-dev \
    libaio-dev \
    libffi-dev \
    openldap-dev \
    openssl-dev \
    mariadb-connector-c-dev \
    freetds-dev \
    postgresql-dev
}


apk_add_repo_azul() {
  wget -P /etc/apk/keys/ \
    https://cdn.azul.com/public_keys/alpine-signing@azul.com-5d5dc44c.rsa.pub
  echo "https://repos.azul.com/zulu/alpine" | tee -a /etc/apk/repositories
}

bazel_install() {
  local ORIG_CFLAGS=$CFLAGS; local ORIG_CXXFLAGS=$CXXFLAGS # saving compiler flags
  unset CFLAGS ; unset CXXFLAGS
  local ENDPOINT="https://github.com/bazelbuild/bazel/releases/download"
  curl -LO "$ENDPOINT/$BAZEL_VERSION/bazel-$BAZEL_VERSION-dist.zip"
  unzip -qd bazel "bazel-$BAZEL_VERSION-dist.zip"
  cd bazel || exit
  export JAVA_HOME=/usr/lib/jvm/default-jvm
  export EXTRA_BAZEL_ARGS="--host_javabase=@local_jdk//:jdk --compilation_mode=opt"
  ./compile.sh && cp ./output/bazel /usr/local/bin
  cd ..
  # restoring compiler flags
  if [ -n "${CFLAGS+x}" ]; then CFLAGS=$ORIG_CFLAGS; fi
  if [ -n "${CXXFLAGS+x}" ]; then CXXFLAGS=$ORIG_CXXFLAGS; fi
}

git_clone_sha() {
  local repo=$1
  local sha=$2
  local dest_dir="${3:-$(basename -s .git "$repo")}"

  echo "cloning $repo into $dest_dir for sha: $sha..."
  git init -q "$dest_dir"
  cd "$dest_dir"
  git remote add origin "$repo"
  git fetch --depth=1 origin "$sha"
  git reset --hard FETCH_HEAD
}
