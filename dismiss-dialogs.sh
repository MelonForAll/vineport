#!/bin/bash
# Monitors for Steam error dialog windows and auto-dismisses them
# by sending Return key via osascript to the frontmost wine process.

while true; do
    sleep 3
    # Check if any wine process has multiple windows (dialog = extra window)
    WINE_WINDOWS=$(osascript -e '
        tell application "System Events"
            set hitCount to 0
            repeat with p in (every process whose name contains "wine")
                set wCount to count of windows of p
                if wCount > 0 then
                    repeat with w in windows of p
                        try
                            set t to name of w
                            -- Match Steam error dialogs (they have titles like "Steam - Error" or just "Steam")
                            if t contains "Error" or t contains "error" or t contains "0x3" then
                                set hitCount to hitCount + 1
                            end if
                        end try
                    end repeat
                end if
            end repeat
            return hitCount
        end tell
    ' 2>/dev/null)

    if [[ "$WINE_WINDOWS" -gt 0 ]] 2>/dev/null; then
        # Send Return key to dismiss the OK button on the error dialog
        osascript -e '
            tell application "System Events"
                repeat with p in (every process whose name contains "wine")
                    repeat with w in windows of p
                        try
                            set t to name of w
                            if t contains "Error" or t contains "error" or t contains "0x3" then
                                set frontmost of p to true
                                delay 0.2
                                key code 36 -- Return key
                            end if
                        end try
                    end repeat
                end repeat
            end tell
        ' 2>/dev/null
    fi
done
