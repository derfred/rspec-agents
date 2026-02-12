#!/bin/bash
# M15: Simple shell script with output for testing output-only mode

echo "stdout: starting"
echo "stderr: initialized" >&2
sleep 0.1
echo "stdout: processing"
echo "stderr: status ok" >&2
sleep 0.1
echo "stdout: complete"
exit 0
