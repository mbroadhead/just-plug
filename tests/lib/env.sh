# tests/lib/env.sh — defaults for the plug env overrides.
# Sourced indirectly via fixture.sh; not used standalone.

: "${JUST_PLUG_GIT_BASE:=https://github.com}"
: "${JUST_PLUG_RAW_BASE:=https://raw.githubusercontent.com}"
export JUST_PLUG_GIT_BASE JUST_PLUG_RAW_BASE
