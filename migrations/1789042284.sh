echo "Serve a TPM-sealed key for unattended Git commit signing"

# ConditionPathExists in the unit keeps it inert on machines without a TPM and
# for users who never create a key, so enabling it for everyone costs nothing
# and the agent is in place for anyone who later creates one.
#
# Nothing here may fail the migration: the runner executes migrations under
# `bash -euo pipefail` and stops the whole queue on a non-zero exit, so a home
# this cannot write to would block every later migration forever.
systemctl --user daemon-reload >/dev/null 2>&1 || true

# `systemctl enable` needs a live user manager, which an update from a TTY does
# not have, so fall back to writing the symlink it would have written.
if ! systemctl --user enable omarchy-tpm-agent.socket >/dev/null 2>&1; then
  wants_dir="$HOME/.config/systemd/user/sockets.target.wants"
  if mkdir -p "$wants_dir" 2>/dev/null && [[ ! -e $wants_dir/omarchy-tpm-agent.socket ]]; then
    ln -sfn /usr/lib/systemd/user/omarchy-tpm-agent.socket \
      "$wants_dir/omarchy-tpm-agent.socket" 2>/dev/null || true
  fi
fi

systemctl --user start omarchy-tpm-agent.socket >/dev/null 2>&1 || true
