# Print the Pulzar banner on an interactive login.
#
# Via profile.d rather than /etc/banner because the banner is generated: it
# renders the wordmark with figlet and reports live state, and /etc/banner is a
# static file cat'd by /etc/profile. Numbered 10 so it lands before the
# provisioning QR (99), which reads as a footer under it.

case "$-" in *i*) ;; *) return ;; esac

[ -x /usr/sbin/pulzr-motd ] || return

# COLUMNS is not exported into a non-login shell on every client, and the motd
# adapts to it — so establish it here rather than letting the logo wrap on a
# narrow serial terminal.
if [ -z "${COLUMNS}" ] && command -v stty >/dev/null 2>&1; then
    COLUMNS="$(stty size 2>/dev/null | cut -d' ' -f2)"
fi
COLUMNS="${COLUMNS:-80}" /usr/sbin/pulzr-motd
