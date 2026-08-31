#!/bin/bash
# Rotates the Traefik dashboard basic-auth password.
#
# Flow: scale traefik down -> prompt for new password -> generate htpasswd
# hash with openssl -> create a new Docker secret -> point traefik-stack.yml
# at it -> redeploy the stack (brings traefik back up) -> drop old secrets.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Local, uncommitted settings (DASHBOARD_HOST) used by traefik-stack.yml
set -a; [[ -f "$SCRIPT_DIR/.env" ]] && . "$SCRIPT_DIR/.env"; set +a
STACK_NAME="traefik"
SERVICE_NAME="traefik_traefik"
STACK_FILE="$SCRIPT_DIR/traefik-stack.yml"
USERS_FILE="$SCRIPT_DIR/traefik_users"
USERNAME="admin"

echo "==> Taking traefik down (scaling ${SERVICE_NAME} to 0)"
docker service scale "${SERVICE_NAME}=0" 2>/dev/null || echo "   (${SERVICE_NAME} not running, skipping scale down)"

restore_on_error() {
  echo "!! Something went wrong. Redeploying stack to bring traefik back up with its current config." >&2
  docker stack deploy -c "$STACK_FILE" "$STACK_NAME" >&2 || true
}
trap restore_on_error ERR

while true; do
  read -r -s -p "New dashboard password for '${USERNAME}': " PASSWORD
  echo
  read -r -s -p "Confirm password: " PASSWORD_CONFIRM
  echo
  if [ "$PASSWORD" != "$PASSWORD_CONFIRM" ]; then
    echo "Passwords do not match, try again."
    continue
  fi
  if [ -z "$PASSWORD" ]; then
    echo "Password cannot be empty, try again."
    continue
  fi
  break
done
unset PASSWORD_CONFIRM

HASH="$(openssl passwd -apr1 "$PASSWORD")"
unset PASSWORD
echo "${USERNAME}:${HASH}" > "$USERS_FILE"

NEW_SECRET_NAME="traefik_users_$(date +%s)"
echo "==> Creating new Docker secret ${NEW_SECRET_NAME}"
docker secret create "$NEW_SECRET_NAME" "$USERS_FILE" > /dev/null

echo "==> Pointing traefik-stack.yml at the new secret"
OLD_SECRET_NAME="$(python3 - "$STACK_FILE" <<'PYEOF'
import re, sys
path = sys.argv[1]
text = open(path).read()
m = re.search(r"^  traefik_users:\n(    external: true\n(?:    name: (\S+)\n)?)", text, re.M)
old_name = m.group(2) if m and m.group(2) else "traefik_users"
print(old_name)
PYEOF
)"

python3 - "$STACK_FILE" "$NEW_SECRET_NAME" <<'PYEOF'
import re, sys
path, new_name = sys.argv[1], sys.argv[2]
text = open(path).read()
pattern = re.compile(r"(^  traefik_users:\n)(    external: true\n)(    name: \S+\n)?", re.M)
def repl(m):
    return f"{m.group(1)}{m.group(2)}    name: {new_name}\n"
text, n = pattern.subn(repl, text)
if n != 1:
    raise SystemExit(f"expected exactly one match for traefik_users secret block, got {n}")
open(path, "w").write(text)
PYEOF

echo "==> Redeploying stack (brings traefik back up)"
docker stack deploy -c "$STACK_FILE" "$STACK_NAME"

trap - ERR

echo "==> Waiting for ${SERVICE_NAME} to come back up"
for i in $(seq 1 30); do
  running="$(docker service ls --filter "name=${SERVICE_NAME}" --format '{{.Replicas}}')"
  echo "   replicas: $running"
  [[ "$running" == 1/1 ]] && break
  sleep 2
done

if [ -n "$OLD_SECRET_NAME" ] && [ "$OLD_SECRET_NAME" != "$NEW_SECRET_NAME" ]; then
  echo "==> Removing old secret ${OLD_SECRET_NAME}"
  docker secret rm "$OLD_SECRET_NAME" 2>/dev/null || echo "   (could not remove, may still be in use - remove manually later)"
fi

# Clean up any other stray traefik_users_* secrets left over from previous runs
for s in $(docker secret ls --format '{{.Name}}' | grep -E '^traefik_users_[0-9]+$' || true); do
  if [ "$s" != "$NEW_SECRET_NAME" ]; then
    docker secret rm "$s" 2>/dev/null || true
  fi
done

echo "==> Done. Dashboard password for '${USERNAME}' has been rotated."
