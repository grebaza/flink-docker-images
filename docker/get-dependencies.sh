#!/usr/bin/env bash

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

VERSION="${1:-1.14.0}"
DEP_JSON="${2:-packages.json}"
VAR_SUFFIX="${3:-_VERSION}"
VAR_PREFIX="${4:-}"
iter=1
while read -rd $'' line
do
  var_name="$VAR_PREFIX$(echo "$line" \
    | sed -r "s/([^=]*)=.*/\1/g" \
    | tr '[:lower:]' '[:upper:]')$VAR_SUFFIX"
  var_value=$(echo "$line" | sed -r "s/([^=]*)=(.*)$/\2/g")
  if [[ $iter == 1 ]]; then sep=''; else sep=' '; fi
  printf "%s $var_name=$var_value" "${sep}--build-arg"
  ((iter++))
done < <(jq -r \
         '."'"$VERSION"'"|to_entries|map("\(.key)=\(.value)\u0000")[]' "$DEP_JSON")