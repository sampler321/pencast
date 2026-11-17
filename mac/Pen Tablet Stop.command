#!/bin/zsh
# Stop the Mac side: PenRelay and Sunshine.
pkill -f "/penrelay"; pkill -x sunshine
echo "Pen tablet host stopped."
