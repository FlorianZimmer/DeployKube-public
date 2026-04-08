#!/usr/bin/env bash
set -euo pipefail

EXPORT_DIR="${NFS_EXPORT_DIR:-/export}"
EXPORT_OPTIONS="${NFS_EXPORT_OPTIONS:-*(rw,sync,no_subtree_check,no_root_squash,fsid=0,crossmnt)}"
NFS_THREADS="${NFS_THREADS:-8}"
MOUNTD_PORT="${NFS_MOUNTD_PORT:-20048}"
STATD_PORT="${NFS_STATD_PORT:-662}"
STATD_OUTGOING_PORT="${NFS_STATD_OUTGOING_PORT:-2020}"
RQUOTAD_PORT="${NFS_RQUOTAD_PORT:-875}"
LOCKD_TCP_PORT="${NFS_LOCKD_TCP_PORT:-32803}"
LOCKD_UDP_PORT="${NFS_LOCKD_UDP_PORT:-32769}"
CALLBACK_TCP_PORT="${NFS_CALLBACK_TCP_PORT:-20049}"

log() {
  printf '[nfs-entrypoint] %s\n' "$*"
}

CLEANED_UP=0
SLEEP_PID=""

cleanup() {
  if (( CLEANED_UP == 1 )); then
    return
  fi
  CLEANED_UP=1

  log "stopping NFS services"
  exportfs -uav >/dev/null 2>&1 || true
  rpc.nfsd 0 >/dev/null 2>&1 || true
  pkill -TERM rpc.mountd >/dev/null 2>&1 || true
  pkill -TERM rpc.statd >/dev/null 2>&1 || true
  pkill -TERM rpc.rquotad >/dev/null 2>&1 || true
  pkill -TERM rpc.idmapd >/dev/null 2>&1 || true
  pkill -TERM rpcbind >/dev/null 2>&1 || true
  if mountpoint -q /proc/fs/nfsd >/dev/null 2>&1; then
    umount /proc/fs/nfsd >/dev/null 2>&1 || true
  fi
  if [[ -n "${SLEEP_PID}" ]]; then
    kill -TERM "${SLEEP_PID}" >/dev/null 2>&1 || true
    wait "${SLEEP_PID}" >/dev/null 2>&1 || true
  fi
}

trap 'cleanup' EXIT
trap 'cleanup; exit 0' TERM INT

log "preparing export directory ${EXPORT_DIR}"
mkdir -p "${EXPORT_DIR}"
chmod 0777 "${EXPORT_DIR}"

cat <<EOF >/etc/exports
${EXPORT_DIR} ${EXPORT_OPTIONS}
EOF

mkdir -p /var/lib/nfs/rpc_pipefs /var/lib/nfs/v4recovery

if command -v modprobe >/dev/null 2>&1; then
  modprobe nfsd >/dev/null 2>&1 || true
  modprobe lockd >/dev/null 2>&1 || true
fi

if [[ -w /proc/sys/fs/nfs/nlm_tcpport ]]; then
  printf '%s\n' "${LOCKD_TCP_PORT}" > /proc/sys/fs/nfs/nlm_tcpport || true
fi
if [[ -w /proc/sys/fs/nfs/nlm_udpport ]]; then
  printf '%s\n' "${LOCKD_UDP_PORT}" > /proc/sys/fs/nfs/nlm_udpport || true
fi
if [[ -w /proc/sys/fs/nfs/nfs_callback_tcpport ]]; then
  printf '%s\n' "${CALLBACK_TCP_PORT}" > /proc/sys/fs/nfs/nfs_callback_tcpport || true
fi

if ! mountpoint -q /proc/fs/nfsd; then
  log "mounting nfsd pseudo-filesystem"
  mount -t nfsd nfsd /proc/fs/nfsd
fi

log "starting rpcbind on all interfaces"
rpcbind -w -h 0.0.0.0 -h :: || rpcbind -w

log "starting rpc.statd on port ${STATD_PORT}"
rpc.statd --no-notify --port "${STATD_PORT}" --outgoing-port "${STATD_OUTGOING_PORT}" >/var/log/rpc.statd.log 2>&1 &

log "starting rpc.idmapd"
rpc.idmapd >/var/log/rpc.idmapd.log 2>&1 &

log "starting rpc.rquotad on port ${RQUOTAD_PORT}"
rpc.rquotad -F -p "${RQUOTAD_PORT}" >/var/log/rpc.rquotad.log 2>&1 &

log "starting rpc.mountd on port ${MOUNTD_PORT}"
rpc.mountd --port "${MOUNTD_PORT}" --manage-gids >/var/log/rpc.mountd.log 2>&1 &

log "starting rpc.nfsd with ${NFS_THREADS} threads"
rpc.nfsd "${NFS_THREADS}"

log "exporting file systems"
if ! exportfs -rv; then
  log "exportfs validation failed"
  exit 1
fi

log "NFS services ready; entering supervision loop"
sleep infinity &
SLEEP_PID=$!
wait "${SLEEP_PID}"
