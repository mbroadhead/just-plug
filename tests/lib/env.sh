# tests/lib/env.sh — defaults for JUST_PLUG_GIT_BASE and JUST_PLUG_RAW_BASE.
# Source this directly from a test that needs to run against the real GitHub
# (most tests use fixture.sh instead and never touch these defaults).

: "${JUST_PLUG_GIT_BASE:=https://github.com}"
: "${JUST_PLUG_RAW_BASE:=https://raw.githubusercontent.com}"
export JUST_PLUG_GIT_BASE JUST_PLUG_RAW_BASE
