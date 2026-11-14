#!/bin/bash
# Runs the volume tests against real disks of the kinds people scan:
#   smb     Samba in a throwaway Docker container, with a guest share on the
#           container's own Linux disk and a read-only share beside it.
#   fruit   the same, served with Samba's macOS extensions, as most NAS do.
#   nfs     an NFSv4 server in a throwaway Docker container, exporting a
#           RAM disk of its own. The server is the Docker VM's kernel one, so
#           the container is privileged; its tools are Alpine's nfs-utils,
#           added to the Samba image once, as image mymole-nfs-test.
#   webdav  this Mac's own Apache serving a folder of a temporary directory.
#   images  disk images standing in for USB sticks and external disks:
#           exFAT, FAT32, APFS, Mac OS Extended and its case-sensitive form, one attached
#           read-only, and one ejected while it's being scanned.
# Every server listens on 127.0.0.1 only; nothing on this Mac is shared.
# Servers, mounts and images are removed afterwards, pass or fail.
# A server is never paused or stopped while mounted: every call on the share
# then waits until it answers again, and the client's connection to that
# server name can stay stuck afterwards.
# Usage: scripts/volume-tests.sh [smb|fruit|nfs|webdav|images]...   (all without arguments)
set -euo pipefail

fail() { printf '%s\n' "$*" >&2; exit 1; }
repo=$(cd "$(dirname "$0")/.." && pwd -P)
# As `mount` lists it, with /var resolved to /private/var.
work=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/mymole-volumes.XXXXXX")" && pwd -P)
mounts=()      # network shares, unmounted
attached=()    # disk images' mount points, detached
images=()      # disk image files, deleted
container=
httpd_conf=
made=          # what mount_point and attach made last

cleanup() {
  set +e
  for m in "${mounts[@]+"${mounts[@]}"}"; do
    if mount | grep -q " on $m "; then umount "$m" 2>/dev/null || diskutil unmount force "$m" >/dev/null; fi
  done
  for m in "${attached[@]+"${attached[@]}"}"; do
    if mount | grep -q " on $m "; then hdiutil detach -quiet -force "$m"; fi
  done
  [ -z "$httpd_conf" ] || /usr/sbin/httpd -f "$httpd_conf" -k stop 2>/dev/null
  [ -z "$container" ] || remove_container
  # Only what this run made, by its exact paths.
  for i in "${images[@]+"${images[@]}"}"; do rm -f "$i"; done
  [ ! -d "$work/dav" ] || rm -rf "$work/dav"
  find "$work" -depth -type d -empty -delete
}
trap cleanup EXIT

# An empty folder in the run's directory, in `made`.
# The NFS server is the Docker VM's own, shared by every container: it's
# stopped before its container goes, or the container can't be removed.
remove_container() {
  docker exec "$container" sh -c 'command -v rpc.nfsd >/dev/null && rpc.nfsd 0 && exportfs -ua' >/dev/null 2>&1 || true
  docker rm -f "$container" >/dev/null 2>&1
  container=
}

mount_point() { made="$work/$1"; mkdir -p "$made"; }

run_tests() {
  (cd "$repo" && env "$@" MYMOLE_REAL_TRASH=1 swift test --filter "$filter")
}

smb() {
  local vfs=$1 host=${MYMOLE_SMB_HOST:-localhost} port=${MYMOLE_SMB_PORT:-1445}
  command -v docker >/dev/null && docker info >/dev/null 2>&1 || fail "Docker isn't running."
  # macOS keeps one SMB connection per server name, whatever the port.
  ! mount | grep -qF "@$host:" || fail "Unmount the other share from $host first: macOS would reuse its connection."
  container=mymole-smb-$$
  docker run -d --name "$container" -p "127.0.0.1:$port:445" \
    -e AVAHI_DISABLE=1 -e WSDD2_DISABLE=1 -e NETBIOS_DISABLE=1 \
    -e "SAMBA_VOLUME_CONFIG_test=[test]; path=/shares/test; guest ok = yes; read only = no$vfs" \
    -e "SAMBA_VOLUME_CONFIG_ro=[ro]; path=/shares/ro; guest ok = yes; read only = yes$vfs" \
    servercontainers/samba@sha256:de2f1c141e497ea287ba099788cb4526859f0b0336214a7e7dcf89d1f90525b7 >/dev/null
  # Written on the server before mounting, so the Mac never shows them with
  # times of its own. What a Mac can't make over SMB: names that differ only
  # by case, each with an exact copy beside it; a link back up the server
  # follows itself; a folder the guest can't open; names Windows forbids.
  docker exec "$container" sh -c '
  set -e
  mkdir -p /shares/ro /shares/test/server-made && cd /shares/test/server-made
  mkdir -p collide copies keep sizes/nested/deeper loop/inner denied/inside names
  head -c 1048576 /dev/urandom > collide/photo.bin
  head -c 1048576 /dev/urandom > collide/Photo.bin
  cp collide/photo.bin collide/copy-of-lower.bin
  cp collide/Photo.bin collide/copy-of-upper.bin
  head -c 400000 /dev/urandom > copies/one.bin
  cp copies/one.bin copies/two.bin
  head -c 400000 /dev/urandom > copies/other.bin
  head -c 50000 /dev/urandom > keep/keep.bin
  head -c 300000 /dev/urandom > sizes/a.bin
  head -c 700000 /dev/urandom > sizes/nested/b.bin
  head -c 1100000 /dev/urandom > sizes/nested/deeper/c.bin
  head -c 200000 /dev/urandom > loop/inner/a.bin
  ln -s .. loop/inner/back
  head -c 200000 /dev/urandom > denied/inside/secret.bin
  for n in "colon:name.bin" "back\\slash.bin" "star*.bin" "question?.bin" "pipe|.bin" "trailing-dot." "trailing-space "; do
    head -c 4096 /dev/zero > "names/$n"
  done
  head -c 300000 /dev/urandom > /shares/ro/fixed.bin
  chmod -R a+rwX /shares/test /shares/ro
  chmod 700 denied'
  mount_point smb; local share=$made; mounts+=("$share")
  mount_point smb-ro; local ro=$made; mounts+=("$ro")
  for _ in $(seq 1 20); do mount_smbfs -N "//guest@$host:$port/test" "$share" 2>/dev/null && break; sleep 0.5; done
  mount | grep -q " on $share " || fail "The share didn't mount."
  mount_smbfs -N "//guest@$host:$port/ro" "$ro" || fail "The read-only share didn't mount."
  filter='NetworkShareTests|CaseTwinNameTests' run_tests MYMOLE_SMB_SHARE="$share" MYMOLE_SMB_READ_ONLY="$ro"
  umount "$ro"; umount "$share"
  remove_container
}

nfs() {
  local port=${MYMOLE_NFS_PORT:-12049}
  command -v docker >/dev/null && docker info >/dev/null 2>&1 || fail "Docker isn't running."
  docker build -q -t mymole-nfs-test:1 - >/dev/null <<'EOF'
FROM servercontainers/samba@sha256:de2f1c141e497ea287ba099788cb4526859f0b0336214a7e7dcf89d1f90525b7
RUN apk add --no-cache nfs-utils
ENTRYPOINT []
EOF
  container=mymole-nfs-$$
  docker run -d --name "$container" --privileged -p "127.0.0.1:$port:2049" --tmpfs /export:size=256m mymole-nfs-test:1 sh -c '
  set -e
  mount -t nfsd nfsd /proc/fs/nfsd 2>/dev/null || true
  echo "/export *(rw,fsid=0,insecure,no_subtree_check,no_root_squash)" > /etc/exports
  exportfs -ra
  # A fresh server refuses to open files for its grace period, 90 seconds
  # unless told otherwise, so clients can reclaim their locks.
  echo 10 > /proc/fs/nfsd/nfsv4leasetime
  echo 10 > /proc/fs/nfsd/nfsv4gracetime
  rpc.nfsd --no-nfs-version 3 --nfs-version 4 8
  exec rpc.mountd --no-nfs-version 3 --nfs-version 4 -F' >/dev/null
  # Written on the server before mounting. A hard link, a link back up,
  # which NFS shows as a link, and names that differ only by case, which
  # NFS keeps apart as the server does, each with an exact copy beside it.
  docker exec "$container" sh -c '
  set -e
  mkdir -p /export/test && cd /export/test
  mkdir -p copies loop/inner collide keep
  head -c 400000 /dev/urandom > copies/one.bin
  cp copies/one.bin copies/two.bin
  ln copies/one.bin copies/one-link.bin
  head -c 400000 /dev/urandom > copies/other.bin
  head -c 200000 /dev/urandom > loop/inner/a.bin
  ln -s .. loop/inner/back
  head -c 300000 /dev/urandom > collide/photo.bin
  head -c 300000 /dev/urandom > collide/Photo.bin
  cp collide/photo.bin collide/copy-of-lower.bin
  cp collide/Photo.bin collide/copy-of-upper.bin
  head -c 50000 /dev/urandom > keep/keep.bin
  chmod -R a+rwX /export'
  mount_point nfs; local share=$made; mounts+=("$share")
  # No callbacks: the server can't reach this Mac through Docker's port
  # mapping, and a read would wait on one.
  for _ in $(seq 1 20); do
    mount_nfs -o vers=4,port="$port",noresvport,soft,intr,timeo=10,nocallback 127.0.0.1:/ "$share" 2>/dev/null && break
    sleep 0.5
  done
  mount | grep -q " on $share " || fail "The NFS export didn't mount."
  filter='NFSShareTests' run_tests MYMOLE_NFS_SHARE="$share/test"
  umount "$share"
  remove_container
}

webdav() {
  local root="$work/dav/root" port=${MYMOLE_WEBDAV_PORT:-8089}
  mkdir -p "$root/copies" "$root/keep" "$work/dav/logs" "$work/dav/lock"
  head -c 400000 /dev/urandom > "$root/copies/one.bin"
  cp "$root/copies/one.bin" "$root/copies/two.bin"
  head -c 400000 /dev/urandom > "$root/copies/other.bin"
  head -c 50000 /dev/urandom > "$root/keep/keep.bin"
  httpd_conf="$work/dav/httpd.conf"
  cat > "$httpd_conf" <<EOF
ServerRoot "/usr"
ServerName localhost
Listen 127.0.0.1:$port
PidFile "$work/dav/logs/httpd.pid"
LoadModule mpm_prefork_module libexec/apache2/mod_mpm_prefork.so
LoadModule authz_core_module libexec/apache2/mod_authz_core.so
LoadModule unixd_module libexec/apache2/mod_unixd.so
LoadModule dav_module libexec/apache2/mod_dav.so
LoadModule dav_fs_module libexec/apache2/mod_dav_fs.so
LoadModule dir_module libexec/apache2/mod_dir.so
LoadModule mime_module libexec/apache2/mod_mime.so
TypesConfig /private/etc/apache2/mime.types
ErrorLog "$work/dav/logs/error.log"
DavLockDB "$work/dav/lock/DavLock"
DocumentRoot "$root"
<Directory "$root">
  Dav On
  Require all granted
</Directory>
EOF
  /usr/sbin/httpd -f "$httpd_conf" -k start
  mount_point dav-mount; local share=$made; mounts+=("$share")
  for _ in $(seq 1 20); do mount_webdav -S -v MyMoleDAV "http://127.0.0.1:$port/" "$share" 2>/dev/null && break; sleep 0.5; done
  mount | grep -q " on $share " || fail "The WebDAV share didn't mount."
  filter='WebDAVShareTests' run_tests MYMOLE_WEBDAV_SHARE="$share"
  umount "$share"
  /usr/sbin/httpd -f "$httpd_conf" -k stop; httpd_conf=
}

# A new disk image of `name` and `fs`, attached at the mount point in `made`.
attach() {
  local name=$1 fs=$2
  hdiutil create -quiet -size 64m -fs "$fs" -volname "MM${name:0:9}" -type UDIF "$work/$name.dmg"
  images+=("$work/$name.dmg")
  mount_point "$name"
  attached+=("$made")
  hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$made" "$work/$name.dmg"
}

disk_images() {
  attach exfat ExFAT; local exfat=$made
  attach fat32 "MS-DOS FAT32"; local fat32=$made
  attach hfsx "HFS+X"; local hfsx=$made
  attach apfs APFS; local apfs=$made
  attach hfs "HFS+"; local hfs=$made
  attach eject "HFS+"; local eject=$made
  attach readonly "HFS+"; local ro=$made
  head -c 300000 /dev/urandom > "$ro/fixed.bin"
  hdiutil detach -quiet "$ro"
  hdiutil attach -quiet -nobrowse -noautoopen -readonly -mountpoint "$ro" "$work/readonly.dmg"
  # Enough folders that a scan is still walking when the disk goes.
  (cd "$eject" && for i in $(seq 1 400); do mkdir -p "f$i/a/b" && : > "f$i/a/b/x" && : > "f$i/a/y"; done)
  filter='RemovableDiskTests' run_tests \
    MYMOLE_DISK_EXFAT="$exfat" MYMOLE_DISK_FAT32="$fat32" MYMOLE_DISK_CASE_SENSITIVE="$hfsx" \
    MYMOLE_DISK_APFS="$apfs" MYMOLE_DISK_HFS="$hfs" \
    MYMOLE_DISK_READ_ONLY="$ro" MYMOLE_DISK_EJECT="$eject"
}

[ "$#" -gt 0 ] || set -- smb fruit nfs webdav images
for kind in "$@"; do
  case "$kind" in
    smb) smb "" ;;
    fruit) smb "; vfs objects = catia fruit streams_xattr; fruit:metadata = stream" ;;
    nfs) nfs ;;
    webdav) webdav ;;
    images) disk_images ;;
    *) fail "Unknown kind: $kind" ;;
  esac
done
