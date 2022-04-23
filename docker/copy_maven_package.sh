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

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

# Settings ==================================================================
: "${MVN_PROJECT_ROOT:=}"
: "${MVN_PROJECT_VERSION:=1.0.0}"
PKG_DIR="$MVN_PROJECT_ROOT/$1"
DEST_DIR="$2"
PKG_NAME="$(basename "$PKG_DIR")"

pushd "$PKG_DIR"
PKG_VERSION="$($SCRIPT_DIR/xmltojson.py pom.xml | jq -r '.project.parent.version')"

cp "$PKG_DIR/target/$PKG_NAME-$PKG_VERSION.jar" "$DEST_DIR"

popd
