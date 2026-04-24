#!/usr/bin/env bash
# Mock agent for consensus dispatch tests.
# Reads MOCK_OUTPUT_<agent> and MOCK_EXIT_<agent> env vars.
# agent is normalized: slashes->underscores, dashes->underscores, dots->underscores
agent="$1"
key="${agent//[\/.-]/_}"
output_var="MOCK_OUTPUT_${key}"
exit_var="MOCK_EXIT_${key}"
printf '%s' "${!output_var:-mock output for $agent}"
exit "${!exit_var:-0}"