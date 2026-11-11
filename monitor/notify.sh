# shellcheck shell=bash
# Sourced by the monitor and deploy scripts; expects REPO_DIR.
#
# notify <text>: write the text to stdout (the journal) and, when the
# installation has an executable instance/notify.sh, hand it the text as its
# only argument: that script delivers it wherever this installation wants its
# alerts (a messenger, mail, a webhook). Never fails the caller.

notify() {
  local hook="$REPO_DIR/instance/notify.sh"
  echo "$1"
  [ -x "$hook" ] || return 0
  REPO_DIR="$REPO_DIR" timeout 60 "$hook" "$1" >/dev/null 2>&1 ||
    echo "notify: instance/notify.sh could not deliver the message"
  return 0
}
