#!/bin/zsh
# Start the Mac side: PenRelay (pen -> tablet events) and, if installed, Sunshine (screen -> Moonlight).
# Sunshine config: set "mouse = disabled" so the pen only arrives once, through PenRelay with pressure.
D="${0:A:h}"
pgrep -f "$D/penrelay" >/dev/null || (nohup "$D/penrelay" >/tmp/penrelay.log 2>&1 &)
if command -v sunshine >/dev/null; then pkill -x sunshine; sleep 2; nohup sunshine >/tmp/sunshine.out 2>&1 & fi
echo "Pen tablet host ready on $(scutil --get LocalHostName).local. Start 'Mac Pen Tablet' on the tablet."
