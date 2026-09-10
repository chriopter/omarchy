#!/bin/bash

set -uo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command git
require_command ssh-keygen

WORKDIR=$(mktemp -d)
cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

# Everything that would reach the real session is stubbed: the user's systemd
# units, desktop notifications, the browser, the clipboard, and the prompts. A
# test that disabled a unit or opened a tab would be a bug in the test, not a
# failure of the command. The stubs answer from STUB_* variables so each case
# can drive the command down the branch it means to exercise, and they log what
# they were called with so the test can assert on it.
STUBS="$WORKDIR/stubs"
mkdir -p "$STUBS"
STUB_LOG="$WORKDIR/calls.log"

stub() {
  printf '#!/bin/bash\nprintf "%s %%s\\n" "$*" >>"$STUB_LOG"\n%s\n' "$1" "$2" >"$STUBS/$1"
  chmod +x "$STUBS/$1"
}

stub systemctl 'case " $* " in *" is-active "*) exit "${STUB_AGENT_INACTIVE:-0}" ;; esac; exit 0'
stub gum 'case ${1-} in
  choose) printf "%s\n" "${STUB_GUM_CHOOSE-}"; exit 0 ;;
  confirm)
    case "${2-}" in
      *PIN*) exit "${STUB_GUM_PIN:-1}" ;;
      *GitHub*) exit "${STUB_GUM_GITHUB:-1}" ;;
      *"Switch to the TPM"*) exit "${STUB_GUM_SIGN:-1}" ;;
      *tss*) exit "${STUB_GUM_TSS:-1}" ;;
      *) exit "${STUB_GUM_CONFIRM:-0}" ;;
    esac
    ;;
  input) printf "%s\n" "${STUB_GUM_INPUT-}"; exit 0 ;;
esac
exit 0'
stub wl-copy 'cat >/dev/null; exit "${STUB_WL_COPY_STATUS:-0}"'
stub omarchy-notification-send 'exit 0'
stub omarchy-launch-browser 'exit 0'
stub omarchy-pkg-add 'exit "${STUB_PKG_ADD_STATUS:-0}"'
stub gh 'exit "${STUB_GH_STATUS:-0}"'

# The command now proves the chip answers instead of trusting systemd, so the
# agent probe and the test signature both need answering. Everything else about
# ssh-keygen (fingerprints, real key generation) passes through untouched.
stub ssh-add 'case " $* " in *" -l "*) exit "${STUB_AGENT_INACTIVE:-0}" ;; esac; exit 0'
cat >"$STUBS/ssh-keygen" <<'KEYGEN'
#!/bin/bash
printf 'ssh-keygen %s\n' "$*" >>"$STUB_LOG"
case " $* " in
  *" -Y sign "*) : >"${@: -1}.sig"; exit "${STUB_CAN_SIGN:-0}" ;;
  *" -Y verify "*) exit "${STUB_CAN_VERIFY:-0}" ;;
esac
exec /usr/bin/ssh-keygen "$@"
KEYGEN
chmod +x "$STUBS/ssh-keygen"

# Stands in for the real ssh-tpm-keygen: a sealed key's contents never matter to
# this command, only that the pair appears where it was asked for.
cat >"$STUBS/ssh-tpm-keygen" <<'KEYGEN'
#!/bin/bash
printf 'ssh-tpm-keygen %s\n' "$*" >>"$STUB_LOG"
[[ -n ${SSH_ASKPASS_REQUIRE-} ]] && printf 'askpass-forced %s\n' "$("$SSH_ASKPASS")" >>"$STUB_LOG"
[[ ${1-} == "--supported" ]] && {
  echo "ecdsa bit lengths: 256 384"
  exit "${STUB_TPM_UNREACHABLE:-0}"
}
target=""
while (( $# )); do
  [[ $1 == "-f" ]] && target=$2
  shift
done
ssh-keygen -q -t ecdsa -b 256 -N '' -C "omarchy-signing@test" -f "$target" || exit 1
mv "$target" "$target.tpm"
exit 0
KEYGEN
chmod +x "$STUBS/ssh-tpm-keygen"

export PATH="$STUBS:$ROOT/bin:$PATH"
export STUB_LOG
export OMARCHY_TPM_DEVICE=/dev/null

signing() {
  HOME="$FAKE_HOME" GIT_CONFIG_GLOBAL="$FAKE_HOME/.gitconfig" \
    omarchy-security-signing "$@"
}

git_here() {
  HOME="$FAKE_HOME" GIT_CONFIG_GLOBAL="$FAKE_HOME/.gitconfig" git "$@"
}

KEY_REL=".local/state/omarchy/tpm-signing/signing"

new_home() {
  FAKE_HOME="$WORKDIR/home-$1"
  mkdir -p "$FAKE_HOME/.ssh" "$FAKE_HOME/$(dirname "$KEY_REL")"
  : >"$FAKE_HOME/.gitconfig"
  : >"$STUB_LOG"
  unset STUB_AGENT_INACTIVE STUB_GUM_INPUT
  unset STUB_GUM_CONFIRM STUB_PKG_ADD_STATUS STUB_TPM_UNREACHABLE STUB_GH_STATUS
  unset STUB_WL_COPY_STATUS STUB_GUM_PIN STUB_GUM_GITHUB STUB_GUM_SIGN STUB_GUM_TSS STUB_CAN_SIGN STUB_CAN_VERIFY STUB_GUM_CHOOSE
}

fake_key() {
  ssh-keygen -q -t ecdsa -b 256 -N '' -C "omarchy-signing@test" \
    -f "$FAKE_HOME/$KEY_REL" >/dev/null 2>&1
  mv "$FAKE_HOME/$KEY_REL" "$FAKE_HOME/$KEY_REL.tpm"
}

key_material() {
  awk '{print $1, $2}' "$FAKE_HOME/$KEY_REL.pub"
}

# --- omarchy-hw-tpm -----------------------------------------------------------

OMARCHY_TPM_DEVICE=/dev/null omarchy-hw-tpm ||
  fail "omarchy-hw-tpm succeeds when the resource manager device exists"
pass "omarchy-hw-tpm succeeds when the resource manager device exists"

OMARCHY_TPM_DEVICE="$WORKDIR/absent" omarchy-hw-tpm &&
  fail "omarchy-hw-tpm fails when there is no TPM"
pass "omarchy-hw-tpm fails when there is no TPM"

# --- omarchy-ssh-sign ---------------------------------------------------------

# git calls the wrapper exactly like ssh-keygen; the wrapper's whole job is to
# point signing at the TPM agent without disturbing the shell's own agent.
cat >"$STUBS/ssh-keygen-probe" <<'PROBE'
#!/bin/bash
printf '%s\n' "$SSH_AUTH_SOCK" "$*"
PROBE
chmod +x "$STUBS/ssh-keygen-probe"
sed 's|exec /usr/bin/ssh-keygen|exec ssh-keygen-probe|' "$ROOT/bin/omarchy-ssh-sign" \
  >"$STUBS/ssh-sign-probe"
chmod +x "$STUBS/ssh-sign-probe"

signed=$(XDG_RUNTIME_DIR="$WORKDIR/run" ssh-sign-probe -Y sign -n git -f key)
[[ $(sed -n 1p <<<"$signed") == "$WORKDIR/run/omarchy-tpm-agent.sock" ]] ||
  fail "omarchy-ssh-sign points signing at the TPM agent socket" "$signed"
pass "omarchy-ssh-sign points signing at the TPM agent socket"

[[ $(sed -n 2p <<<"$signed") == "-Y sign -n git -f key" ]] ||
  fail "omarchy-ssh-sign forwards its arguments to ssh-keygen" "$signed"
pass "omarchy-ssh-sign forwards its arguments to ssh-keygen"

# The wrapper and the unit have to name the same socket or signing reaches
# nothing, and nothing else in the tree ties the two files together.
unit_socket=$(sed -n 's/^ListenStream=%t\/\(.*\)/\1/p' \
  "$ROOT/default/systemd/user/omarchy-tpm-agent.socket")
wrapper_socket=$(sed -n 's/.*XDG_RUNTIME_DIR:-[^}]*}\/\([^"]*\)".*/\1/p' \
  "$ROOT/bin/omarchy-ssh-sign")
[[ -n $unit_socket && $unit_socket == "$wrapper_socket" ]] ||
  fail "the socket unit and the signing wrapper agree on the path" \
    "unit: $unit_socket, wrapper: $wrapper_socket"
pass "the socket unit and the signing wrapper agree on the path"

# --- verb dispatch ------------------------------------------------------------

new_home dispatch
signing bogus-verb >/dev/null 2>&1
(($? == 2)) || fail "an unknown verb exits 2"
pass "an unknown verb exits 2"

help_text=$(signing --help 2>&1)
grep -q "authentication key list" <<<"$help_text" ||
  fail "--help says the key is kept out of the authentication list" "$help_text"
grep -q "prevents it being used to log in" <<<"$help_text" ||
  fail "--help does not claim signing-only is a property of the key" "$help_text"
pass "--help describes the signing-only policy honestly"

report=$(OMARCHY_TPM_DEVICE="$WORKDIR/absent" signing status 2>&1)
grep -q "No TPM on this machine" <<<"$report" ||
  fail "status reports a missing TPM" "$report"
grep -q "^Git:" <<<"$report" ||
  fail "status still reports the Git configuration without a TPM" "$report"
pass "status reports a missing TPM and still describes the Git configuration"

OMARCHY_TPM_DEVICE="$WORKDIR/absent" signing setup >/dev/null 2>&1 &&
  fail "the wizard refuses on a machine with no TPM"
pass "the wizard refuses on a machine with no TPM"

# --- create -------------------------------------------------------------------

new_home create
signing setup >/dev/null 2>&1 || fail "the wizard creates a key when the TPM is reachable"
[[ -f $FAKE_HOME/$KEY_REL.tpm && -f $FAKE_HOME/$KEY_REL.pub ]] ||
  fail "create writes both halves of the key"
pass "create writes both halves of the key"

grep -q 'ssh-tpm-keygen.*-t ecdsa -b 256' "$STUB_LOG" ||
  fail "create asks for an ECDSA P-256 key" "$(cat "$STUB_LOG")"
pass "create asks for an ECDSA P-256 key"

# `-N ""` is not "no passphrase": ssh-tpm-keygen drops the empty value and
# prompts, which blocks on a terminal and fails without one. An askpass that
# answers with nothing is what actually makes the key passphraseless.
grep -q 'askpass-forced' "$STUB_LOG" ||
  fail "create forces an empty askpass answer instead of passing -N" "$(cat "$STUB_LOG")"
pass "create forces an empty askpass answer instead of passing -N"

[[ $(stat -c '%a' "$FAKE_HOME/$KEY_REL.tpm") == "600" ]] ||
  fail "create restricts the sealed key to its owner"
pass "create restricts the sealed key to its owner"

# The key must land outside ~/.ssh, or the agent would serve every other sealed
# key the user owns alongside it.
[[ -f $FAKE_HOME/.ssh/signing.tpm ]] &&
  fail "create keeps the key out of ~/.ssh"
pass "create keeps the key out of ~/.ssh"

# Declining the PIN has to produce a passphraseless key, and accepting it has to
# leave -N off the command line entirely: a PIN passed as an argument would be
# readable by every process on the machine.
new_home create-pin
STUB_GUM_PIN=0 signing setup >/dev/null 2>&1 || fail "the wizard creates a key with a PIN"
keygen_call=$(grep '^ssh-tpm-keygen' "$STUB_LOG" | grep -v -- '--supported')
[[ $keygen_call != *"-N"* ]] ||
  fail "a PIN is never passed on the command line" "$keygen_call"
pass "a PIN is never passed on the command line"

new_home create-no-tpm
OMARCHY_TPM_DEVICE="$WORKDIR/absent" signing setup >/dev/null 2>&1 &&
  fail "the wizard refuses on a machine with no TPM (create step)"
pass "the wizard refuses on a machine with no TPM (create step)"

# A failed package install leaves no ssh-tpm-keygen, which must not be mistaken
# for a missing group and must never reach the usermod.
new_home create-pkg-fails
STUB_PKG_ADD_STATUS=1 signing setup >/dev/null 2>&1 &&
  fail "create stops when ssh-tpm-agent cannot be installed"
grep -q "usermod" "$STUB_LOG" &&
  fail "create does not grant tss membership when the install failed"
pass "create stops when ssh-tpm-agent cannot be installed, without granting tss"

# --- the group takes effect at the next boot, not the next login ------------

# Omarchy's systemd user manager survives a logout and hands its old group list
# to the next session, so "log out and back in" sends the user round a loop
# that cannot work. Only a reboot refreshes it.
new_home tss-stale
stub id 'case "$*" in
  *-nG*) printf "%s\n" "${STUB_GROUPS:-christopher tss}" ;;
  *-un*) printf "%s\n" "christopher" ;;
esac
exit 0'
advice=$(STUB_TPM_UNREACHABLE=1 signing setup 2>&1)
rm -f "$STUBS/id"

grep -qi "reboot" <<<"$advice" ||
  fail "create says a reboot is needed when the group is not live yet" "$advice"
pass "create says a reboot is needed when the group is not live yet"

grep -qi "log out" <<<"$advice" &&
  fail "create does not send the user round the logout loop" "$advice"
pass "create does not send the user round the logout loop"

# --- omarchy-ssh-askpass ------------------------------------------------------

# A PIN-protected key is unusable unless the agent, which never has a terminal,
# can ask for it. pinentry answers in Assuan, which percent-encodes its payload.
stub pinentry-curses 'echo OK; echo "D hunter%25two"; echo OK'
asked=$(WAYLAND_DISPLAY= DISPLAY= omarchy-ssh-askpass "Enter the PIN" 2>/dev/null)
[[ $asked == 'hunter%two' ]] ||
  fail "askpass returns the decoded secret from pinentry" "got: [$asked]"
pass "askpass returns the decoded secret from pinentry"

stub pinentry-curses 'echo OK; echo OK'
WAYLAND_DISPLAY= DISPLAY= omarchy-ssh-askpass "Enter the PIN" >/dev/null 2>&1 &&
  fail "askpass fails when pinentry returns no secret"
pass "askpass fails when pinentry returns no secret"

rm -f "$STUBS/pinentry-curses"

# The unit has to name the askpass, or a PIN-protected key can never be used.
grep -q 'SSH_ASKPASS=/usr/bin/omarchy-ssh-askpass' \
  "$ROOT/default/systemd/user/omarchy-tpm-agent.service" ||
  fail "the unit points the agent at the askpass helper"
pass "the unit points the agent at the askpass helper"

# --- github -------------------------------------------------------------------

new_home github
fake_key
mkdir -p "$FAKE_HOME/.config/gh"
: >"$FAKE_HOME/.config/gh/hosts.yml"
STUB_GUM_GITHUB=0 signing setup >/dev/null 2>&1
grep -q 'gh ssh-key add.*--type signing' "$STUB_LOG" ||
  fail "github registers the key as a signing key" "$(cat "$STUB_LOG")"
pass "github registers the key as a signing key"

grep -q -- '--type authentication' "$STUB_LOG" &&
  fail "github never registers the key for authentication"
pass "github never registers the key for authentication"

# Without a gh config the CLI is never probed, because the launcher is a lazy
# stub that would download the whole thing to answer.
new_home github-no-gh
fake_key
STUB_GUM_GITHUB=0 signing setup >/dev/null 2>&1
grep -q '^gh ' "$STUB_LOG" &&
  fail "github leaves gh alone when it was never configured"
grep -q '^wl-copy' "$STUB_LOG" ||
  fail "github falls back to the clipboard" "$(cat "$STUB_LOG")"
grep -q '^omarchy-launch-browser https://github.com/settings/ssh/new' "$STUB_LOG" ||
  fail "github opens the key form in the default browser" "$(cat "$STUB_LOG")"
pass "github leaves gh alone when unconfigured, copies the key and opens the form"

# --- github: a failing gh falls back to the form without noise ---------------

new_home github-no-scope
fake_key
mkdir -p "$FAKE_HOME/.config/gh"
: >"$FAKE_HOME/.config/gh/hosts.yml"
# The stub has to speak like the real thing, or redirecting its stderr would
# be untestable: nothing leaks when nothing is written.
stub gh 'echo "HTTP 404: Not Found. This API operation needs the \"admin:ssh_signing_key\" scope." >&2; exit 1'
report=$(STUB_GUM_GITHUB=0 signing setup 2>&1)
stub gh 'exit "${STUB_GH_STATUS:-0}"' 

grep -qi "scope\|gh auth\|HTTP" <<<"$report" &&
  fail "a failing gh does not spill its error into the wizard" "$report"
grep -q '^omarchy-launch-browser' "$STUB_LOG" ||
  fail "a failing gh still opens the form" "$(cat "$STUB_LOG")"
pass "a failing gh falls back to the form without noise"

# --- show ---------------------------------------------------------------------

new_home show
fake_key
grep -qF "$(key_material)" <<<"$(signing setup 2>/dev/null)" ||
  fail "the wizard prints the public key"
pass "the wizard prints the public key"

# --- install: global ----------------------------------------------------------

new_home install-global
fake_key
git_here config --global user.email "someone@example.com"
STUB_GUM_SIGN=0 signing setup >/dev/null 2>&1 || fail "the wizard enables signing"

for setting in "gpg.format ssh" "gpg.ssh.program $(command -v omarchy-ssh-sign)" \
  "user.signingkey $FAKE_HOME/$KEY_REL.pub" "commit.gpgsign true" \
  "gpg.ssh.allowedsignersfile $FAKE_HOME/.ssh/allowed_signers"; do
  actual=$(git_here config --global "${setting%% *}")
  [[ $actual == "${setting#* }" ]] ||
    fail "install writes ${setting%% *}" "got: $actual"
done
pass "install writes every signing setting"

grep -qF "$(key_material)" "$FAKE_HOME/.ssh/allowed_signers" ||
  fail "install trusts the key in allowed_signers"
pass "install trusts the key in allowed_signers"

grep -q "Git: signing through the TPM" <<<"$(signing status 2>/dev/null)" ||
  fail "status reports that signing is installed"
pass "status reports that signing is installed"

# --- install: the agent has to be there ---------------------------------------

new_home install-no-agent
fake_key
git_here config --global user.email "someone@example.com"
STUB_AGENT_INACTIVE=1 STUB_GUM_SIGN=0 signing setup >/dev/null 2>&1 &&
  fail "install refuses when the agent never comes up"
[[ -z $(git_here config --global commit.gpgsign) ]] ||
  fail "install leaves Git alone when the agent never comes up"
pass "install refuses, and leaves Git alone, when the agent never comes up"

# --- wipe ---------------------------------------------------------------------

new_home wipe
fake_key
material=$(key_material)
printf 'someone@example.com %s\n' "$material" >"$FAKE_HOME/.ssh/allowed_signers"
printf 'other@example.com ssh-ed25519 AAAAsomeoneelse\n' >>"$FAKE_HOME/.ssh/allowed_signers"
git_here config --global gpg.ssh.program "$(command -v omarchy-ssh-sign)"
signing wipe >/dev/null 2>&1

[[ -f $FAKE_HOME/$KEY_REL.tpm || -f $FAKE_HOME/$KEY_REL.pub ]] &&
  fail "wipe removes both halves of the key"
pass "wipe removes both halves of the key"

grep -qF "$material" "$FAKE_HOME/.ssh/allowed_signers" &&
  fail "wipe drops the key from allowed_signers"
pass "wipe drops the key from allowed_signers"

grep -q "other@example.com" "$FAKE_HOME/.ssh/allowed_signers" ||
  fail "wipe keeps other signers in allowed_signers"
pass "wipe keeps other signers in allowed_signers"

grep -q 'systemctl.*disable.*omarchy-tpm-agent' "$STUB_LOG" ||
  fail "wipe disables the agent unit" "$(cat "$STUB_LOG")"
pass "wipe disables the agent unit"

# --- wipe: this key is the only trusted signer --------------------------------

new_home only-signer
fake_key
material=$(key_material)
printf 'someone@example.com %s\n' "$material" >"$FAKE_HOME/.ssh/allowed_signers"
signing wipe >/dev/null 2>&1
grep -qF "$material" "$FAKE_HOME/.ssh/allowed_signers" &&
  fail "wipe drops the key even when it is the only signer listed"
pass "wipe drops the key even when it is the only signer listed"

# --- wipe: an empty public key must not empty allowed_signers -----------------

# An interrupted write leaves a zero-byte .pub. Deriving an empty pattern from
# it and filtering with it would delete every trusted signer the user has.
new_home empty-pub
fake_key
: >"$FAKE_HOME/$KEY_REL.pub"
printf 'alice@example.com ssh-ed25519 AAAAalice\nbob@example.com ssh-ed25519 AAAAbob\n' \
  >"$FAKE_HOME/.ssh/allowed_signers"
signing wipe >/dev/null 2>&1

remaining=$(wc -l <"$FAKE_HOME/.ssh/allowed_signers")
((remaining == 2)) ||
  fail "an empty public key leaves allowed_signers untouched" "$remaining lines left"
pass "an empty public key leaves allowed_signers untouched"

[[ -f $FAKE_HOME/$KEY_REL.tpm ]] &&
  fail "wipe still removes a sealed key whose public half is empty"
pass "wipe still removes a sealed key whose public half is empty"

# --- wipe: half-written pair --------------------------------------------------

new_home partial
fake_key
rm -f "$FAKE_HOME/$KEY_REL.pub"
signing wipe >/dev/null 2>&1
[[ -f $FAKE_HOME/$KEY_REL.tpm ]] &&
  fail "wipe removes a sealed key whose public half is missing"
pass "wipe removes a sealed key whose public half is missing"

# --- wipe: keys gone, global config still installed ---------------------------

# Deleting the key files by hand used to leave commit.gpgsign on with nothing to
# sign with, and wipe answered "Nothing to remove."
new_home orphaned-config
git_here config --global gpg.ssh.program "$(command -v omarchy-ssh-sign)"
git_here config --global commit.gpgsign true
signing wipe >/dev/null 2>&1
[[ -z $(git_here config --global gpg.ssh.program) ]] ||
  fail "wipe cleans a global install whose key files are already gone"
pass "wipe cleans a global install whose key files are already gone"

# --- wipe leaves a foreign signing setup alone --------------------------------

new_home foreign
fake_key
git_here config --global gpg.ssh.program /opt/1Password/op-ssh-sign
git_here config --global user.signingkey "ssh-ed25519 AAAAtheirkey"
signing wipe >/dev/null 2>&1

[[ $(git_here config --global gpg.ssh.program) == "/opt/1Password/op-ssh-sign" ]] ||
  fail "wipe leaves another signing program configured"
[[ $(git_here config --global user.signingkey) == "ssh-ed25519 AAAAtheirkey" ]] ||
  fail "wipe leaves another signing key configured"
pass "wipe leaves another signing setup alone"

# --- the wizard names what signs today before offering to switch --------------

new_home current-signer
fake_key
git_here config --global user.email "someone@example.com"
git_here config --global gpg.format ssh
git_here config --global gpg.ssh.program /opt/1Password/op-ssh-sign
git_here config --global commit.gpgsign true
report=$(signing setup 2>&1)

grep -q "currently signed by: 1Password" <<<"$report" ||
  fail "the wizard names the signer it is about to replace" "$report"
pass "the wizard names the signer it is about to replace"

# --- wipe offers the way back to 1Password ------------------------------------

new_home back-to-1password
fake_key
mkdir -p "$FAKE_HOME/.1password"
python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])" \
  "$FAKE_HOME/.1password/agent.sock"
git_here config --global gpg.ssh.program "$(command -v omarchy-ssh-sign)"
stub ssh-add 'case " $* " in
  *" -L "*) printf "ssh-ed25519 AAAAtheirkey their@key\n" ;;
  *" -l "*) exit "${STUB_AGENT_INACTIVE:-0}" ;;
esac
exit 0'
STUB_GUM_CHOOSE="ssh-ed25519 AAAAtheirkey their@key" signing wipe >/dev/null 2>&1

if [[ -x /opt/1Password/op-ssh-sign ]]; then
  [[ $(git_here config --global gpg.ssh.program) == "/opt/1Password/op-ssh-sign" ]] ||
    fail "wipe points Git back at 1Password" "$(git_here config --global gpg.ssh.program)"
  pass "wipe points Git back at 1Password"
else
  pass "wipe offers 1Password only where it is installed (skipped: not installed)"
fi

# --- setup proves it works before claiming it does ----------------------------

new_home proof
fake_key
git_here config --global user.email "someone@example.com"
report=$(STUB_GUM_SIGN=0 signing setup 2>&1)
grep -q "signed a test file with the key and verified it" <<<"$report" ||
  fail "setup signs and verifies a test file" "$report"
pass "setup signs and verifies a test file before reporting success"

# A chip that signs while the trust store says otherwise is a working commit
# nobody accepts, so that must not read as success either.
new_home proof-unverifiable
fake_key
git_here config --global user.email "someone@example.com"
STUB_CAN_VERIFY=1 STUB_GUM_SIGN=0 signing setup >/dev/null 2>&1 &&
  fail "setup fails when the signature does not verify"
pass "setup fails when the signature does not verify"

# --- an existing install is re-checked, not just acknowledged ----------------

new_home already
fake_key
git_here config --global user.email "someone@example.com"
git_here config --global gpg.ssh.program "$(command -v omarchy-ssh-sign)"
git_here config --global commit.gpgsign true
report=$(signing setup 2>&1)

grep -q "already signs through the TPM" <<<"$report" ||
  fail "an existing install is recognised" "$report"
grep -q "signed a test file with the key and verified it" <<<"$report" ||
  fail "an existing install is re-checked, not just acknowledged" "$report"
pass "an existing install is re-checked rather than just acknowledged"

# And a setup that has quietly stopped working must say so.
new_home already-broken
fake_key
git_here config --global user.email "someone@example.com"
git_here config --global gpg.ssh.program "$(command -v omarchy-ssh-sign)"
git_here config --global commit.gpgsign true
STUB_CAN_SIGN=1 signing setup >/dev/null 2>&1 &&
  fail "an existing install that cannot sign is reported as broken"
pass "an existing install that cannot sign is reported as broken"

# --- an install from an older version is still recognised ---------------------

# Earlier versions wrote the bare name, which git resolved through PATH. If that
# no longer counts as installed, an upgrade reads as a foreign signer and
# neither status nor wipe will touch it.
new_home legacy
fake_key
git_here config --global gpg.ssh.program omarchy-ssh-sign
git_here config --global commit.gpgsign true

grep -q "Git: signing through the TPM" <<<"$(signing status 2>/dev/null)" ||
  fail "status recognises an install that used the bare program name"
pass "status recognises an install that used the bare program name"

signing wipe >/dev/null 2>&1
[[ -z $(git_here config --global gpg.ssh.program) ]] ||
  fail "wipe cleans up an install that used the bare program name" \
    "$(git_here config --global gpg.ssh.program)"
pass "wipe cleans up an install that used the bare program name"

# --- wipe hands back the group it was granted ---------------------------------

new_home tss-return
fake_key
stub id 'case "$*" in *-nG*) printf "%s\n" "christopher tss" ;; *) printf "christopher\n" ;; esac
exit 0'
stub sudo 'printf "sudo %s\n" "$*" >>"$STUB_LOG"; exit 0'
stub omarchy-state 'exit 0'
STUB_GUM_TSS=0 signing wipe >/dev/null 2>&1
rm -f "$STUBS/id" "$STUBS/sudo" "$STUBS/omarchy-state"

grep -q 'sudo gpasswd -d christopher tss' "$STUB_LOG" ||
  fail "wipe offers the tss membership back" "$(cat "$STUB_LOG")"
pass "wipe hands back the tss group membership"

# --- the change is wired into the rest of the tree ----------------------------

grep -q 'omarchy-tpm-agent.socket' "$ROOT/install/user/first-run/enable-user-units.sh" ||
  fail "the agent socket is enabled at first run"
pass "the agent socket is enabled at first run"

grep -q 'GROUP_DESCRIPTIONS\[security\]' "$ROOT/bin/omarchy" ||
  fail "the security command group is described in the router"
pass "the security command group is described in the router"

for unit in omarchy-tpm-agent.service omarchy-tpm-agent.socket; do
  grep -q "$unit" "$ROOT/test/shell.d/config-test.sh" ||
    fail "$unit is listed for PKGBUILD coverage"
done
pass "both agent units are listed for PKGBUILD coverage"

entries=$(grep -c 'security.signing' "$ROOT/default/omarchy/omarchy-menu.jsonc")
((entries == 2)) ||
  fail "the menu carries one setup entry and one removal entry" "found $entries"
pass "the menu carries one setup entry and one removal entry"
