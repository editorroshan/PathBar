#!/bin/bash
# Double-click to install or update PathBar (opens Terminal and runs install.sh).
cd "$(dirname "$0")" || exit 1
bash ./install.sh
echo
read -n1 -r -p "Press any key to close this window."
