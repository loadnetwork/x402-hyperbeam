#!/bin/bash
set -e

echo "[*] starting the ~x402@1.0 hyperbeam node"
echo "[*] building ~x402@1.0 device"
./build.sh

echo "[*] starting hyperbeam node"
rebar3 shell