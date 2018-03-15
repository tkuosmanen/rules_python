#!/bin/sh
set -e

REQUIREMENTS_TXT="%{requirements_txt}"
REQUIREMENTS_FIX="%{requirements_fix}"
REQUIREMENTS_BZL="%{requirements_bzl}"
if [ -z "$REQUIREMENTS_BZL" ]; then
    REQUIREMENTS_BZL=$(dirname $(realpath "$REQUIREMENTS_TXT"))/requirements.bzl
fi
REQUIREMENTS_BZL_TEMP="requirements.bzl.tmp"
echo "Generating $REQUIREMENTS_BZL from $REQUIREMENTS_TXT..."

if [ -n "$REQUIREMENTS_FIX" ]; then
    REQUIREMENTS_FIX="--input-fix $REQUIREMENTS_FIX"
fi

python "%{piptool}" \
    --name "%{name}" \
    --input "$REQUIREMENTS_TXT" \
    --output "$REQUIREMENTS_BZL_TEMP" \
    $REQUIREMENTS_FIX \
    --output-format download \
    --directory "%{directory}" -- %{pip_args}

cp "$REQUIREMENTS_BZL_TEMP" "$REQUIREMENTS_BZL"
echo "$REQUIREMENTS_BZL updated!"