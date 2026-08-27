#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'usage: validate-ref-name.sh REF_NAME\n' >&2
  exit 64
fi
ref_name="$1"

if [[ ! "$ref_name" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] ||
   [[ "$ref_name" == */ ]] ||
   [[ "$ref_name" == *.lock ]] ||
   [[ "$ref_name" == *'@{'* ]] ||
   [[ "$ref_name" == *..* ]] ||
   [[ "$ref_name" == *. ]]; then
  printf 'invalid tracked ref name: %s\n' "$ref_name" >&2
  exit 64
fi
case "/$ref_name/" in
  */../*|*/./*|*//*)
    printf 'invalid tracked ref path: %s\n' "$ref_name" >&2
    exit 64
    ;;
esac
