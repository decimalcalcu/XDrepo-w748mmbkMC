#!/usr/bin/env bash
# 发布工具会填入固定 tag、归档 SHA256 和独立 Ed25519 公钥。
# 初始信任来自用户事先核对的本脚本及其 SHA256；不建议 curl | bash。
set -euo pipefail
umask 077

HOST="${PVE_HOST:-}"
ARCHIVE_URL='https://github.com/decimalcalcu/XDrepo-w748mmbkMC/releases/download/maintenance-v10.27.1/pve-maintenance-base-10.27.1.tar.gz'
ARCHIVE_SHA256='b3618499694e9bf86c32e64f753a1afe02687d1e2cf3c86960af73857e0331da'

[[ -n "$HOST" ]] || { echo '请先设置 PVE_HOST 为宿主实际单播 IP。' >&2; exit 2; }
[[ "$(id -u)" = 0 && "$(uname -s)" = Linux && "$(uname -m)" = x86_64 ]] || {
    echo '需要 Linux x86_64 root。' >&2; exit 2;
}
for command in curl sha256sum tar openssl mktemp chmod; do
    command -v "$command" >/dev/null || { echo "缺少前置工具：$command" >&2; exit 2; }
done
[[ "$ARCHIVE_SHA256" =~ ^[a-f0-9]{64}$ ]] || { echo '请使用已填充固定版本的发布安装器。' >&2; exit 2; }

work=$(mktemp -d /var/tmp/pve-maintenance-install.XXXXXXXX)
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/bundle"
cat > "$work/trusted-installer-key.pem" <<'PVE_TRUSTED_PUBLIC_KEY'
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAA/yjw8pgkHk2xwGMyv4BMtsMZ2D3+BM5m7+zJ2fGx2M=
-----END PUBLIC KEY-----
PVE_TRUSTED_PUBLIC_KEY
curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
    "$ARCHIVE_URL" --output "$work/base.tar.gz"
printf '%s  %s\n' "$ARCHIVE_SHA256" "$work/base.tar.gz" | sha256sum --check --status
# SHA 来自可信安装器，而不是下载归档内的声明；只有核对后才解包/执行。
tar -xzf "$work/base.tar.gz" -C "$work/bundle" --no-same-owner --no-same-permissions
chmod 0755 "$work/bundle/base/python/bin/python3.12"
export PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1 PYTHONUTF8=1
export PYTHONPATH="$work/bundle/site:$work/bundle/base/deps"
export LD_LIBRARY_PATH="$work/bundle/base/python/lib:$work/bundle/base/native"
"$work/bundle/base/python/bin/python3.12" -u -B -m pve_maintenance.first_install \
    --bundle "$work/bundle" --trusted-key "$work/trusted-installer-key.pem" --host "$HOST"
printf '初始化完成：https://%s:8887/；正式控制台安装后使用 8888。\n' "$HOST"
