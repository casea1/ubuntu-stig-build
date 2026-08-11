#!/bin/bash
# =============================================================================
# GUI logon consent banner -- shown at the start of EVERY graphical session
# (local console AND xrdp/RDP). xrdp bypasses the GDM greeter, so the GDM
# login-screen banner never appears over RDP; this autostart closes that gap by
# presenting the same warning/consent text and requiring acknowledgement before
# the user proceeds. Declining (or closing the dialog) logs the session out.
#
# The banner text is written by the desktop_hardening role to BANNER_FILE
# (gui_banner_text: the DCSA banner, or the unclassified-EMI banner on that
# variant). Managed by ansible -- do not edit by hand.
# =============================================================================
set -u

BANNER_FILE=/etc/gui-consent-banner.txt

# No banner text -> do nothing (never block login on a missing file).
[ -s "$BANNER_FILE" ] || exit 0
TEXT="$(cat "$BANNER_FILE")"

# zenity is the acknowledgement dialog. If it is somehow missing, fail OPEN
# (log a warning, allow the session) rather than locking users out of the box.
if ! command -v zenity >/dev/null 2>&1; then
    logger -t gui-consent-banner "zenity not found; skipping consent gate"
    exit 0
fi

# --question with custom buttons = an explicit I Agree / Decline choice. Closing
# the window (X) or Decline both return non-zero -> treated as "declined".
if zenity --question \
        --title="Notice and Consent -- Authorized Use Only" \
        --no-wrap \
        --ok-label="I Agree" \
        --cancel-label="Decline (log out)" \
        --width=760 \
        --text="$TEXT" 2>/dev/null; then
    exit 0
fi

# Declined -> end the graphical session. Try the clean GNOME logout first, then
# fall back to terminating the systemd session, then a hard kill of the user's
# processes as a last resort.
logger -t gui-consent-banner "consent declined by ${USER:-unknown}; logging out"
gnome-session-quit --logout --no-prompt 2>/dev/null && exit 0
[ -n "${XDG_SESSION_ID:-}" ] && loginctl terminate-session "$XDG_SESSION_ID" 2>/dev/null && exit 0
loginctl terminate-user "$(id -u)" 2>/dev/null && exit 0
pkill -KILL -u "$(id -un)"
exit 0
