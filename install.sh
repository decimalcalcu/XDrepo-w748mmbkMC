#!/usr/bin/env bash
RELEASE_REPOSITORY="decimalcalcu/XDrepo-w748mmbkMC"
RELEASE_TAG="bootstrap-v0.1.0"
BUNDLE_SHA256="28745472bb2fe3b57bb293902994d13f6a79d7be5d01e68c79ed240a71f3138c"

set -Eeuo pipefail
umask 077
PYTHON_BIN="${PYTHON_BIN:-python3}"
INSTALL_ROOT=/opt/twcn-pve/bootstrap
STATE_DIR=/var/lib/twcn-pve/bootstrap
CONFIG_DIR=/etc/twcn-pve
UNIT=twcn-pve-bootstrap.service
PORT=8088
EXPECTED_BOOTSTRAP_VERSION="0.1.0"

die() { printf '%s\n' "安装停止：$*" >&2; exit 1; }

validate_install_root() {
    local target="$1"
    [[ "$target" == /opt/twcn-pve/bootstrap ]] || die "程序目录必须严格为 /opt/twcn-pve/bootstrap"
    [[ ! -L "$target" && "$(readlink -m -- "$target")" == /opt/twcn-pve/bootstrap ]] || die "安装目录存在链接或路径漂移，保留现状"
}

show_management_address() {
    printf '管理地址：https://%s:%s\n' "$1" "$PORT"
    if [[ -f "$STATE_DIR/bootstrap-token.txt" ]]; then
        printf '首次令牌文件：%s/bootstrap-token.txt\n' "$STATE_DIR"
    fi
    printf '首次访问请确认 HTTPS 证书。\n'
}

reject_path_links() {
    "$PYTHON_BIN" - "$1" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
try:
    if not path.is_absolute() or ".." in path.parts:
        raise ValueError("需要规范绝对路径")
    for item in (path, *path.parents):
        if item.is_symlink() or getattr(item, "is_junction", lambda: False)():
            raise ValueError("保留路径或父目录存在符号链接")
    if path.resolve(strict=False) != path:
        raise ValueError("保留路径发生真实路径漂移")
except (OSError, RuntimeError, ValueError) as exc:
    raise SystemExit(f"路径链接审查停止：{exc}") from None
PY
}

require_root_controlled() {
    "$PYTHON_BIN" - "$1" <<'PY'
import os, pathlib, stat, sys
path = pathlib.Path(sys.argv[1])
for item in (path, *path.parents):
    if item.exists():
        info = item.lstat()
        if stat.S_ISLNK(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise SystemExit("目录/文件不是 root 独占写入，保留现状请人工审查")
PY
}

validate_preserved_paths() {
    local path
    for path in "$INSTALL_ROOT" "$INSTALL_ROOT/releases" "$STATE_DIR" "$CONFIG_DIR" \
        "$CONFIG_DIR/bootstrap.env" "$CONFIG_DIR/tls" "$CONFIG_DIR/tls/certificate.pem" \
        "$CONFIG_DIR/tls/private-key.pem" "$STATE_DIR/tls" "$STATE_DIR/tls/certificate.pem" "$STATE_DIR/tls/private-key.pem"; do
        reject_path_links "$path"
    done
    for path in "$INSTALL_ROOT" "$INSTALL_ROOT/releases" "$(dirname -- "$STATE_DIR")" "$CONFIG_DIR" \
        "$CONFIG_DIR/bootstrap.env" "$CONFIG_DIR/tls" "$CONFIG_DIR/tls/certificate.pem" "$CONFIG_DIR/tls/private-key.pem"; do
        require_root_controlled "$path"
    done
    if [[ -e "$STATE_DIR/tls/certificate.pem" || -e "$STATE_DIR/tls/private-key.pem" ]]; then
        die "发现旧状态目录 TLS 材料；保留原件，请人工审查后迁移到 root 管理的 /etc/twcn-pve/tls"
    fi
}

validate_saved_tls_config() {
    if [[ -e "$CONFIG_DIR/bootstrap.env" ]]; then
        [[ "$(config_value TWCN_BOOTSTRAP_CERT)" == "$CONFIG_DIR/tls/certificate.pem" \
            && "$(config_value TWCN_BOOTSTRAP_KEY)" == "$CONFIG_DIR/tls/private-key.pem" ]] \
            || die "既有 TLS 配置不是 root 管理的固定路径；保留配置，请人工审查，不静默迁移"
        [[ -f "$CONFIG_DIR/tls/certificate.pem" && -f "$CONFIG_DIR/tls/private-key.pem" ]] \
            || die "既有配置缺少完整 TLS 材料，请人工审查"
        validate_production_tls_permissions
    fi
}

validate_production_tls_permissions() {
    "$PYTHON_BIN" - "$CONFIG_DIR/tls" <<'PY'
import grp, pathlib, stat, sys
directory = pathlib.Path(sys.argv[1])
gid = grp.getgrnam("twcn-pve").gr_gid
for path, mode, directory_expected in ((directory, 0o750, True), (directory / "certificate.pem", 0o640, False), (directory / "private-key.pem", 0o640, False)):
    info = path.lstat()
    expected_type = stat.S_ISDIR(info.st_mode) if directory_expected else stat.S_ISREG(info.st_mode)
    if not expected_type or info.st_uid != 0 or info.st_gid != gid or stat.S_IMODE(info.st_mode) != mode:
        raise SystemExit("生产 TLS 权限需 root:twcn-pve，目录0750、证书/私钥0640；保留原件请人工审查")
PY
}

prepare_tls() {
    local path
    for path in "$STATE_DIR/tls" "$STATE_DIR/tls/certificate.pem" "$STATE_DIR/tls/private-key.pem" \
        "$CONFIG_DIR" "$CONFIG_DIR/tls" "$CONFIG_DIR/tls/certificate.pem" "$CONFIG_DIR/tls/private-key.pem"; do
        reject_path_links "$path"
    done
    [[ ! -e "$STATE_DIR/tls/certificate.pem" && ! -e "$STATE_DIR/tls/private-key.pem" ]] \
        || die "发现旧 TLS 材料，请人工审查，不静默迁移"
    require_root_controlled "$CONFIG_DIR"
    cert="$CONFIG_DIR/tls/certificate.pem"
    key="$CONFIG_DIR/tls/private-key.pem"
    if [[ -e "$cert" || -e "$key" ]]; then
        [[ -f "$cert" && -f "$key" ]] || die "既有 TLS 材料不完整，请人工审查"
        require_root_controlled "$CONFIG_DIR/tls"
        require_root_controlled "$cert"
        require_root_controlled "$key"
        validate_production_tls_permissions
        return
    fi
    install -d -m 0750 -o root -g twcn-pve "$CONFIG_DIR/tls"
    require_root_controlled "$CONFIG_DIR/tls"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -sha256 -days 365 -nodes \
        -keyout "$temp/tls-key.pem" -out "$temp/tls-cert.pem" -subj '/CN=TWCN PVE bootstrap' \
        -addext "subjectAltName=IP:$lan_ip,DNS:$hostname_fqdn,DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1
    "$PYTHON_BIN" - "$temp/tls-cert.pem" "$cert" "$temp/tls-key.pem" "$key" <<'PY'
import grp, os, pathlib, sys
gid = grp.getgrnam("twcn-pve").gr_gid
for source, target in ((sys.argv[1], sys.argv[2]), (sys.argv[3], sys.argv[4])):
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o640)
    with os.fdopen(fd, "wb") as stream:
        stream.write(pathlib.Path(source).read_bytes())
        stream.flush()
        os.fsync(stream.fileno())
        os.fchown(stream.fileno(), 0, gid)
        os.fchmod(stream.fileno(), 0o640)
PY
    validate_production_tls_permissions
}

validate_cleanup_path() {
    local target="$1" kind="$2"
    case "$kind" in
        temp) [[ "$target" =~ ^/tmp/twcn-pve-bootstrap\.[A-Za-z0-9]{8}$ ]] || die "临时清理目录越界" ;;
        stage) [[ "$target" =~ ^/opt/twcn-pve/bootstrap/releases/\.stage\.[A-Za-z0-9]{8}$ ]] || die "暂存清理目录越界" ;;
        *) die "未知清理目录类型" ;;
    esac
    [[ ! -L "$target" && "$(readlink -m -- "$target")" == "$target" ]] || die "清理目录实路径发生漂移"
}

validate_service_port() {
    [[ "$1" == 8088 ]] || die "首次安装器固定使用 8088 端口；既有自定义端口配置保留，请人工部署"
}

verify_health() {
    "$PYTHON_BIN" - "$1" "$EXPECTED_BOOTSTRAP_VERSION" <<'PY'
import json, pathlib, sys
try:
    payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
    if not isinstance(payload, dict) or payload.get("status") != "ok" or payload.get("service") != "pve-bootstrap" or payload.get("version") != sys.argv[2]:
        raise ValueError("服务或版本不符合预期")
except (OSError, ValueError) as exc:
    raise SystemExit(f"健康响应校验失败：{exc}") from None
PY
}

verify_release_config() {
    if [[ -n "${BOOTSTRAP_BUNDLE:-}" ]]; then
        [[ -f "$BOOTSTRAP_BUNDLE" ]] || die "本地发布包不存在"
        [[ "${BOOTSTRAP_BUNDLE_SHA256:-}" =~ ^[[:xdigit:]]{64}$ ]] || die "本地包必须显式提供有效 SHA256"
    else
        [[ "$RELEASE_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$RELEASE_TAG" =~ ^[A-Za-z0-9_.-]+$ && "$BUNDLE_SHA256" =~ ^[[:xdigit:]]{64}$ ]] || die "在线发布仓库、固定版本及内置 SHA256 尚未配置"
    fi
}

verify_bundle() {
    "$PYTHON_BIN" - "$1" "$2" <<'PY'
import hashlib, pathlib, re, sys
path, expected = pathlib.Path(sys.argv[1]), sys.argv[2]
if not re.fullmatch(r"[0-9a-fA-F]{64}", expected):
    raise SystemExit("SHA256 格式错误")
digest = hashlib.file_digest(path.open("rb"), "sha256").hexdigest()
if digest != expected.lower():
    raise SystemExit("SHA256 校验失败")
PY
}

extract_bundle() {
    "$PYTHON_BIN" - "$1" "$2" <<'PY'
import pathlib, shutil, sys, tarfile
source, destination = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
try:
    with tarfile.open(source, "r:gz") as archive:
        members, names, total = [], set(), 0
        for item in archive:
            if len(members) >= 10000:
                raise ValueError("条目过多")
            name = pathlib.PurePosixPath(item.name)
            if name.is_absolute() or ".." in name.parts or "\\" in item.name or ":" in item.name or not name.parts:
                raise ValueError("路径非安全相对路径")
            normalized = name.as_posix()
            if normalized in names or not (item.isfile() or item.isdir()) or item.issparse():
                raise ValueError("重复条目、链接或特殊文件")
            if item.size < 0:
                raise ValueError("负数大小")
            total += item.size
            if total > 512 * 1024 * 1024:
                raise ValueError("解包总大小超限")
            members.append(item)
            names.add(normalized)
        required = {"启动维护页.py", "pve_bootstrap/app.py", "pve_bootstrap/settings.py", "requirements-linux.lock", "deploy/twcn-pve-bootstrap.service"}
        files = {pathlib.PurePosixPath(item.name).as_posix() for item in members if item.isfile()}
        if not required <= files or not any(name.startswith("wheelhouse/") and name.endswith(".whl") for name in files):
            raise ValueError("缺少固定结构或离线 wheelhouse")
        if destination.exists() and any(destination.iterdir()):
            raise ValueError("暂存目录非空")
        destination.mkdir(parents=True, exist_ok=True, mode=0o700)
        for item in members:
            target = destination / pathlib.PurePosixPath(item.name)
            if item.isdir():
                target.mkdir(parents=True, exist_ok=True, mode=0o755)
            else:
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
                with archive.extractfile(item) as src, target.open("xb") as out:
                    shutil.copyfileobj(src, out, length=1024 * 1024)
                target.chmod(0o644)
except (OSError, ValueError, tarfile.TarError) as exc:
    raise SystemExit(f"归档校验/解包失败：{exc}") from None
PY
}

preflight() {
    [[ "$EUID" -eq 0 ]] || die "请在 PVE 宿主以 root 运行首次安装器"
    [[ -r /etc/os-release && -d /run/systemd/system ]] || die "需要真实 Debian/PVE systemd 宿主"
    grep -Eq '^ID=(debian|"debian")$' /etc/os-release || die "需要 Debian/PVE 宿主"
    local command
    for command in pveversion systemctl apt-get ip ss flock useradd groupadd getent install readlink; do
        command -v "$command" >/dev/null || die "缺少 PVE 系统基础命令：$command"
    done
    pveversion | grep -q '^pve-manager/' || die "pveversion 未确认 PVE 宿主"
    PYTHON_BIN=python3
    local need_packages=0
    for command in curl openssl python3; do
        command -v "$command" >/dev/null || need_packages=1
    done
    [[ -s /etc/ssl/certs/ca-certificates.crt ]] || need_packages=1
    python3 -c 'import venv,ensurepip' >/dev/null 2>&1 || need_packages=1
    if [[ "$need_packages" -eq 1 ]]; then
        apt-get -qq update
        DEBIAN_FRONTEND=noninteractive apt-get install -qq -y --no-install-recommends python3 python3-venv curl ca-certificates openssl
    fi
    python3 -c 'import sys,venv,ensurepip; assert sys.version_info >= (3, 11)' || die "需要 Python 3.11+ 和系统 venv/ensurepip"
}

config_value() {
    "$PYTHON_BIN" - "$CONFIG_DIR/bootstrap.env" "$1" <<'PY'
import pathlib, sys
for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    key, separator, value = line.partition("=")
    if separator and key == sys.argv[2]:
        print(value.strip().strip('"'))
        break
PY
}

install_bootstrap() {
    verify_release_config
    validate_install_root "$INSTALL_ROOT"
    preflight
    validate_preserved_paths
    validate_saved_tls_config
    exec 9>/run/lock/twcn-pve-bootstrap.lock
    flock -n 9 || die "已有首次安装操作进行中"
    temp=""; stage=""; old_target=""; activated=0; service_was_active=0; unit_created=0
    local lan_ip hostname_fqdn bundle digest release cert key allow_hosts health_host
    temp=$(mktemp -d /tmp/twcn-pve-bootstrap.XXXXXXXX)
    cleanup() {
        local result=$?
        trap - EXIT
        if [[ "$result" -ne 0 && "$activated" -eq 1 ]]; then
            systemctl stop "$UNIT" >/dev/null 2>&1 || true
            if [[ -n "$old_target" ]]; then
                ln -s "$old_target" "$INSTALL_ROOT/.restore.$$"
                mv -Tf "$INSTALL_ROOT/.restore.$$" "$INSTALL_ROOT/current"
                [[ "$service_was_active" -eq 0 ]] || systemctl start "$UNIT" || true
            else
                rm -f -- "$INSTALL_ROOT/current"
                systemctl disable "$UNIT" >/dev/null 2>&1 || true
                if [[ "$unit_created" -eq 1 ]]; then
                    rm -f -- "/etc/systemd/system/$UNIT"
                    systemctl daemon-reload || true
                fi
            fi
            printf '%s\n' "首次启动失败，已撤销本轮 bootstrap 激活；私有数据与证书保留。" >&2
        fi
        if [[ -n "$stage" ]]; then
            validate_cleanup_path "$stage" stage
            rm -rf -- "$stage"
        fi
        validate_cleanup_path "$temp" temp
        rm -rf -- "$temp"
        exit "$result"
    }
    trap cleanup EXIT
    if [[ -n "${BOOTSTRAP_BUNDLE:-}" ]]; then
        bundle=$(readlink -f -- "$BOOTSTRAP_BUNDLE")
        digest=${BOOTSTRAP_BUNDLE_SHA256,,}
    else
        bundle="$temp/bootstrap.tar.gz"
        digest=${BUNDLE_SHA256,,}
        curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 300 \
            "https://github.com/$RELEASE_REPOSITORY/releases/download/$RELEASE_TAG/bootstrap-linux.tar.gz" -o "$bundle"
    fi
    verify_bundle "$bundle" "$digest"
    lan_ip=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1);exit}}')
    [[ "$lan_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "未检测到 PVE LAN IPv4 地址"
    hostname_fqdn=$(hostname -f)
    [[ "$hostname_fqdn" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die "宿主名称不是有效 DNS 名称"
    release="$INSTALL_ROOT/releases/$digest"
    if [[ -e "$CONFIG_DIR/bootstrap.env" ]]; then
        validate_service_port "$(config_value TWCN_BOOTSTRAP_PORT)"
    fi
    if [[ -L "$INSTALL_ROOT/current" ]]; then
        old_target=$(readlink -f -- "$INSTALL_ROOT/current")
        [[ "$old_target" == "$INSTALL_ROOT/releases/"* && -d "$old_target" ]] || die "既有 current 不指向本模块 releases"
    elif [[ -e "$INSTALL_ROOT/current" ]]; then
        die "current 已存在但不是受管版本链接"
    fi
    if [[ "$old_target" == "$release" ]] && systemctl is-active --quiet "$UNIT"; then
        health_host=$(config_value TWCN_BOOTSTRAP_ALLOWED_HOSTS)
        health_host=${health_host%%,*}
        cert=$(config_value TWCN_BOOTSTRAP_CERT)
        [[ "$health_host" =~ ^[A-Za-z0-9.-]+$ && -f "$cert" ]] || die "既有配置需人工检查"
        curl --fail --silent --show-error --noproxy '*' --connect-timeout 2 --max-time 5 --cacert "$cert" "https://$health_host:$PORT/healthz" > "$temp/health.json"
        verify_health "$temp/health.json"
        show_management_address "$health_host"
        return
    fi
    [[ -z "$(ss -H -ltn "sport = :$PORT")" ]] || die "8088 端口已占用，保留现有进程；更换版本请走经过审核的独立维护流程"
    systemctl is-active --quiet "$UNIT" && service_was_active=1
    getent group twcn-pve >/dev/null || groupadd --system twcn-pve
    id -u twcn-pve >/dev/null 2>&1 || useradd --system --gid twcn-pve --home-dir "$STATE_DIR" --no-create-home --shell /usr/sbin/nologin twcn-pve
    [[ "$(id -u twcn-pve)" -ne 0 ]] || die "twcn-pve 必须为非 root 账号"
    install -d -m 0755 "$INSTALL_ROOT" "$INSTALL_ROOT/releases"
    install -d -m 0700 -o twcn-pve -g twcn-pve "$STATE_DIR"
    install -d -m 0750 -o root -g twcn-pve "$CONFIG_DIR"
    validate_preserved_paths
    prepare_tls
    if [[ ! -e "$CONFIG_DIR/bootstrap.env" ]]; then
        (set -o noclobber; cat > "$CONFIG_DIR/bootstrap.env" <<EOF
TWCN_BOOTSTRAP_HOST=0.0.0.0
TWCN_BOOTSTRAP_PORT=$PORT
TWCN_BOOTSTRAP_DATA_DIR=$STATE_DIR
TWCN_BOOTSTRAP_ALLOWED_HOSTS=$lan_ip,$hostname_fqdn,localhost,127.0.0.1
TWCN_BOOTSTRAP_CERT=$cert
TWCN_BOOTSTRAP_KEY=$key
EOF
        )
        chmod 0640 "$CONFIG_DIR/bootstrap.env"
        chown root:twcn-pve "$CONFIG_DIR/bootstrap.env"
    fi
    health_host=$(config_value TWCN_BOOTSTRAP_ALLOWED_HOSTS)
    health_host=${health_host%%,*}
    cert=$(config_value TWCN_BOOTSTRAP_CERT)
    [[ "$health_host" =~ ^[A-Za-z0-9.-]+$ && -f "$cert" ]] || die "既有配置的访问地址或证书需人工检查"
    if [[ ! -d "$release" ]]; then
        stage=$(mktemp -d "$INSTALL_ROOT/releases/.stage.XXXXXXXX")
        extract_bundle "$bundle" "$stage"
        python3 -m venv "$stage/.venv"
        "$stage/.venv/bin/python" -m pip install --quiet --no-index --no-cache-dir --require-hashes \
            --find-links "$stage/wheelhouse" -r "$stage/requirements-linux.lock"
        chmod -R a+rX "$stage"
        mv -T "$stage" "$release"
        stage=""
    fi
    if [[ ! -e "/etc/systemd/system/$UNIT" ]]; then
        install -m 0644 "$release/deploy/$UNIT" "/etc/systemd/system/$UNIT"
        unit_created=1
    else
        cmp -s "$release/deploy/$UNIT" "/etc/systemd/system/$UNIT" || die "既有 unit 与模板不同，保留人工配置，请先审核"
    fi
    ln -s "$release" "$INSTALL_ROOT/.current.$$"
    mv -Tf "$INSTALL_ROOT/.current.$$" "$INSTALL_ROOT/current"
    activated=1
    systemctl daemon-reload
    systemctl --quiet enable "$UNIT"
    systemctl start "$UNIT"
    local healthy=0
    for attempt in {1..20}; do
        if curl --fail --silent --show-error --noproxy '*' --connect-timeout 2 --max-time 5 --cacert "$cert" "https://$health_host:$PORT/healthz" > "$temp/health.json" 2>/dev/null; then
            if verify_health "$temp/health.json"
            then healthy=1; break; fi
        fi
        sleep 1
    done
    [[ "$healthy" -eq 1 ]] || die "HTTPS 基础维护页健康检查失败"
    activated=0
    show_management_address "$health_host"
}

main() {
    install_bootstrap
}

if [[ "${BOOTSTRAP_LIBRARY_ONLY:-0}" != 1 ]]; then
    main "$@"
fi
