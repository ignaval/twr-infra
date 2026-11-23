#!/bin/sh
# alert.sh: the one way monitoring here tells a human something is wrong (or fine again).
#
# usage: alert.sh KEY fail|ok MESSAGE      stateful: one alert per outage, one recovery
#        alert.sh --now fail|ok MESSAGE    send now, no state (monitor.yml keeps its own)
#        alert.sh --test                   send a test message
#
# KEY names one condition (peer-us, cert, disk, ...). With KEY, `fail` sends only if no alert
# for KEY is open, and `ok` sends a recovery only if one is. A message that could not be sent
# (no route, an error, or the hourly cap) records nothing, so the next run tries again.
#
# Routes, from the root-only env file ${ALERT_ENV_FILE:-/etc/twr-relay/alert.env} (KEY=VALUE
# lines, read without running them as shell) or, where there is no file, the environment:
#   ALERT_WEBHOOK_URL    https URL that gets the message as a POST body, with ntfy-style
#                        Title/Priority/Tags headers (for example https://ntfy.sh/<topic>)
#   ALERT_WEBHOOK_TOKEN  optional, sent as "Authorization: Bearer <token>"
#   ALERT_SMTP_URL       optional mail relay, smtps://host:465 or smtp://host:587 (STARTTLS
#                        required either way)
#   ALERT_SMTP_USER, ALERT_SMTP_PASSWORD, ALERT_EMAIL_FROM, ALERT_EMAIL_TO
# Other settings: ALERT_LABEL (default: the host name), ALERT_STATE_DIR (default
# /var/lib/twr-relay-monitor/alerts), ALERT_MAX_PER_HOUR (default 10, all keys together).

set -eu
umask 077

prog=alert
say() {
    printf '%s: %s\n' "$prog" "$*" >&2
}

env_file=${ALERT_ENV_FILE:-/etc/twr-relay/alert.env}
state_dir=${ALERT_STATE_DIR:-/var/lib/twr-relay-monitor/alerts}

# load_env FILE: KEY=VALUE lines for the known keys only; quotes around a value are removed.
load_env() {
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "" | "#"*) continue ;;
            *=*) ;;
            *) continue ;;
        esac
        k=${line%%=*}
        v=${line#*=}
        case "$v" in
            \"*\") v=${v#\"}; v=${v%\"} ;;
            \'*\') v=${v#\'}; v=${v%\'} ;;
        esac
        # The placeholder of alert.env.example counts as unset.
        if [ "$v" = REPLACE_ME ]; then
            v=""
        fi
        case "$k" in
            ALERT_WEBHOOK_URL | ALERT_WEBHOOK_TOKEN | ALERT_SMTP_URL | ALERT_SMTP_USER | \
                ALERT_SMTP_PASSWORD | ALERT_EMAIL_FROM | ALERT_EMAIL_TO | ALERT_LABEL | \
                ALERT_MAX_PER_HOUR)
                eval "$k=\$v"
                ;;
        esac
    done < "$1"
}

if [ -r "$env_file" ]; then
    load_env "$env_file"
fi
label=${ALERT_LABEL:-$(hostname 2> /dev/null || echo unknown-host)}
max_per_hour=${ALERT_MAX_PER_HOUR:-10}
case "$max_per_hour" in
    "" | *[!0-9]*) max_per_hour=10 ;;
esac

# No value may break out of the curl config file it is written into.
nl=$(printf '\nx')
nl=${nl%x}
cr=$(printf '\r')
safe() {
    case "$1" in
        *'"'* | *\\* | *"$nl"* | *"$cr"*) return 1 ;;
    esac
    return 0
}

work=$(mktemp -d "${TMPDIR:-/tmp}/twr-alert.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM

send_webhook() {
    url=${ALERT_WEBHOOK_URL:-}
    [ -n "$url" ] || return 2
    case "$url" in
        https://*) ;;
        *) say "ALERT_WEBHOOK_URL is not an https URL; not sent"; return 1 ;;
    esac
    for v in "$url" "$title" "${ALERT_WEBHOOK_TOKEN:-}"; do
        safe "$v" || { say "an alert setting holds a quote, backslash or newline; not sent"; return 1; }
    done
    {
        printf 'url = "%s"\n' "$url"
        printf 'header = "Title: %s"\n' "$title"
        printf 'header = "Priority: %s"\n' "$priority"
        printf 'header = "Tags: %s"\n' "$tags"
        printf 'header = "Content-Type: text/plain; charset=utf-8"\n'
        if [ -n "${ALERT_WEBHOOK_TOKEN:-}" ]; then
            printf 'header = "Authorization: Bearer %s"\n' "$ALERT_WEBHOOK_TOKEN"
        fi
    } > "$work/webhook.conf"
    printf '%s\n' "$body" > "$work/body"
    curl -fsS --proto '=https' --tlsv1.2 --max-time 20 --retry 2 -o /dev/null \
        -K "$work/webhook.conf" --data-binary "@$work/body"
}

send_mail() {
    url=${ALERT_SMTP_URL:-}
    [ -n "$url" ] || return 2
    case "$url" in
        smtps://* | smtp://*) ;;
        *) say "ALERT_SMTP_URL is not smtp:// or smtps://; not sent"; return 1 ;;
    esac
    from=${ALERT_EMAIL_FROM:-}
    to=${ALERT_EMAIL_TO:-}
    [ -n "$from" ] && [ -n "$to" ] || { say "ALERT_EMAIL_FROM and ALERT_EMAIL_TO are needed for mail"; return 1; }
    for v in "$url" "$from" "$to" "${ALERT_SMTP_USER:-}" "${ALERT_SMTP_PASSWORD:-}" "$title"; do
        safe "$v" || { say "an alert setting holds a quote, backslash or newline; not sent"; return 1; }
    done
    {
        printf 'url = "%s"\n' "$url"
        printf 'mail-from = "%s"\n' "$from"
        printf 'mail-rcpt = "%s"\n' "$to"
        if [ -n "${ALERT_SMTP_USER:-}" ]; then
            printf 'user = "%s:%s"\n' "$ALERT_SMTP_USER" "${ALERT_SMTP_PASSWORD:-}"
        fi
    } > "$work/mail.conf"
    {
        printf 'From: %s\r\n' "$from"
        printf 'To: %s\r\n' "$to"
        printf 'Subject: %s\r\n' "$title"
        printf 'Date: %s\r\n' "$(LC_ALL=C date -R)"
        printf 'Content-Type: text/plain; charset=utf-8\r\n\r\n'
        printf '%s\r\n' "$body"
    } > "$work/mail.txt"
    curl -fsS --ssl-reqd --max-time 30 -K "$work/mail.conf" --upload-file "$work/mail.txt"
}

# send KIND MESSAGE: through every configured route; succeeds if one route took it.
send() {
    if [ "$1" = fail ]; then
        title="twr relay $label: PROBLEM"
        priority=high
        tags=warning
    else
        title="twr relay $label: recovered"
        priority=default
        tags=white_check_mark
    fi
    body="$2"

    mkdir -p "$state_dir"
    sent_log="$state_dir/.sent"
    now=$(date +%s)
    recent=0
    if [ -f "$sent_log" ]; then
        recent=$(awk -v t=$((now - 3600)) '$1 > t' "$sent_log" | wc -l | tr -d ' ')
    fi
    if [ "$recent" -ge "$max_per_hour" ]; then
        say "not sent, $recent alerts in the last hour (cap ALERT_MAX_PER_HOUR=$max_per_hour): $title: $body"
        return 1
    fi

    delivered=""
    rc=0
    send_webhook || rc=$?
    case "$rc" in
        0) delivered=1 ;;
        2) ;;
        *) say "the webhook did not take the alert" ;;
    esac
    rc=0
    send_mail || rc=$?
    case "$rc" in
        0) delivered=1 ;;
        2) ;;
        *) say "the mail relay did not take the alert" ;;
    esac
    if [ -z "$delivered" ]; then
        if [ -z "${ALERT_WEBHOOK_URL:-}" ] && [ -z "${ALERT_SMTP_URL:-}" ]; then
            say "no alert route configured (ALERT_WEBHOOK_URL or ALERT_SMTP_URL in $env_file): $title: $body"
        fi
        return 1
    fi
    # Keep a day of send times for the cap.
    {
        if [ -f "$sent_log" ]; then awk -v t=$((now - 86400)) '$1 > t' "$sent_log"; fi
        echo "$now"
    } > "$sent_log.new"
    mv -f "$sent_log.new" "$sent_log"
    say "sent: $title: $body"
}

case "${1:-}" in
    --test)
        send ok "test message from alert.sh on $label"
        exit
        ;;
    --now)
        [ $# -eq 3 ] || { say "usage: alert.sh --now fail|ok MESSAGE"; exit 64; }
        case "$2" in fail | ok) ;; *) say "the state is fail or ok"; exit 64 ;; esac
        send "$2" "$3"
        exit
        ;;
esac

[ $# -eq 3 ] || { say "usage: alert.sh KEY fail|ok MESSAGE (see the header of $0)"; exit 64; }
key=$1
case "$key" in
    "" | *[!a-z0-9-]*) say "KEY is lowercase letters, digits and dashes"; exit 64 ;;
esac
open="$state_dir/$key.open"
case "$2" in
    fail)
        if [ -f "$open" ]; then
            exit 0
        fi
        send fail "$3"
        mkdir -p "$state_dir"
        printf '%s %s\n' "$(date +%s)" "$3" > "$open"
        ;;
    ok)
        if [ ! -f "$open" ]; then
            exit 0
        fi
        since=$(awk 'NR == 1 { print $1 }' "$open")
        minutes=$((($(date +%s) - ${since:-0}) / 60))
        send ok "$3 (the problem lasted about $minutes minutes)"
        rm -f "$open"
        ;;
    *)
        say "the state is fail or ok"
        exit 64
        ;;
esac
