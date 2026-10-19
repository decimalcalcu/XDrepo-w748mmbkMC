#!/usr/bin/env bash
RELEASE_REPOSITORY="decimalcalcu/XDrepo-w748mmbkMC"
RELEASE_TAG="bootstrap-v0.1.3"
BUNDLE_SHA256="66eddf558a1fc6da7e532d4c8d57aebf45f1403257ced59be6b3b0c019b10505"

set -Eeuo pipefail
umask 077
PYTHON_BIN="${PYTHON_BIN:-python3}"
INSTALL_ROOT=/opt/twcn-pve/bootstrap
STATE_DIR=/var/lib/twcn-pve/bootstrap
CONFIG_DIR=/etc/twcn-pve
UNIT=twcn-pve-bootstrap.service
UNIT_PATH=/etc/systemd/system/$UNIT
LOCK_FILE=/run/lock/twcn-pve-bootstrap.lock
PORT=8088
EXPECTED_BOOTSTRAP_VERSION="0.1.3"
BACKUP_ROOT=/var/backups/twcn-pve-bootstrap

die() { printf '%s\n' "安装停止：$*" >&2; exit 1; }

validate_install_root() {
    local target="$1"
    [[ "$target" == /opt/twcn-pve/bootstrap ]] || die "程序目录必须严格为 /opt/twcn-pve/bootstrap"
    [[ ! -L "$target" && "$(readlink -m -- "$target")" == /opt/twcn-pve/bootstrap ]] || die "安装目录存在链接或路径漂移，保留现状"
}

show_management_address() {
    printf '管理地址：https://%s:%s\n' "$1" "$PORT"
    printf '首次访问请确认 HTTPS 证书。\n'
}

validate_managed_unit() {
    local load_state fragment dropins reload
    [[ -n "$old_target" && -f "$old_target/deploy/$UNIT" && -f "$UNIT_PATH" && ! -L "$UNIT_PATH" ]] \
        || die "服务不是受管版本，保留现状请人工审查"
    require_root_controlled "$old_target/deploy/$UNIT"
    require_root_controlled "$UNIT_PATH"
    cmp -s "$old_target/deploy/$UNIT" "$UNIT_PATH" || die "既有 unit 发生漂移，保留现状请人工审查"
    load_state=$(systemctl show --property=LoadState --value "$UNIT") || die "unit 查询失败，保留现状"
    fragment=$(systemctl show --property=FragmentPath --value "$UNIT") || die "unit 查询失败，保留现状"
    dropins=$(systemctl show --property=DropInPaths --value "$UNIT") || die "unit 查询失败，保留现状"
    reload=$(systemctl show --property=NeedDaemonReload --value "$UNIT") || die "unit 查询失败，保留现状"
    [[ "$load_state" == loaded && "$fragment" == "$UNIT_PATH" && -z "$dropins" && "$reload" == no ]] \
        || die "既有 unit 加载状态发生漂移，保留现状请人工审查"
}

validate_service_listener() {
    local listeners main_pid line remaining found
    listeners=$(ss -H -ltnp "sport = :$PORT") || die "端口归属查询失败，保留现状"
    if [[ "$service_was_active" -eq 1 ]]; then
        validate_managed_unit
    fi
    [[ -n "$listeners" ]] || return 0
    [[ "$service_was_active" -eq 1 ]] || die "8088 端口属于其他进程，保留现状"
    main_pid=$(systemctl show --property=MainPID --value "$UNIT") || die "主进程查询失败，保留现状"
    [[ "$main_pid" =~ ^[1-9][0-9]*$ ]] || die "服务主进程不明，保留现状"
    while IFS= read -r line; do
        remaining="$line"; found=0
        while [[ "$remaining" =~ pid=([0-9]+) ]]; do
            [[ "${BASH_REMATCH[1]}" == "$main_pid" ]] || die "8088 端口含外来进程，保留现状"
            remaining=${remaining#*"${BASH_REMATCH[0]}"}
            found=1
        done
        [[ "$found" -eq 1 ]] || die "8088 端口所有者不明，保留现状"
    done <<< "$listeners"
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
    for command in pveversion systemctl apt-get ip ss flock useradd groupadd getent install readlink cmp; do
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
    exec 9>"$LOCK_FILE"
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
                    rm -f -- "$UNIT_PATH"
                    systemctl daemon-reload || true
                fi
            fi
            printf '%s\n' "激活失败，已尝试恢复原版；请核对服务状态。" >&2
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
    if systemctl is-active --quiet "$UNIT"; then service_was_active=1; fi
    validate_service_listener
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
    if [[ ! -e "$UNIT_PATH" ]]; then
        install -m 0644 "$release/deploy/$UNIT" "$UNIT_PATH"
        unit_created=1
    else
        cmp -s "$release/deploy/$UNIT" "$UNIT_PATH" || die "既有 unit 与模板不同，保留人工配置，请先审核"
        validate_managed_unit
    fi
    local still_active=0
    if systemctl is-active --quiet "$UNIT"; then still_active=1; fi
    [[ "$still_active" -eq "$service_was_active" ]] || die "服务状态已变化，保留现状请重试"
    validate_service_listener
    activated=1
    if [[ "$service_was_active" -eq 1 ]]; then systemctl stop "$UNIT"; fi
    local remaining_listeners
    remaining_listeners=$(ss -H -ltnp "sport = :$PORT") || die "端口归属查询失败，恢复旧版"
    [[ -z "$remaining_listeners" ]] || die "8088 端口仍被占用，保留进程并恢复旧版"
    ln -s "$release" "$INSTALL_ROOT/.current.$$"
    mv -Tf "$INSTALL_ROOT/.current.$$" "$INSTALL_ROOT/current"
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

uninstall_preflight() {
    [[ "$EUID" -eq 0 ]] || die "请以 root 运行"
    local command
    for command in systemctl ss flock readlink cmp mv cp rm mkdir chmod mktemp stat "$PYTHON_BIN"; do
        command -v "$command" >/dev/null || die "缺少系统命令：$command"
    done
    validate_install_root "$INSTALL_ROOT"
    [[ "$UNIT" == twcn-pve-bootstrap.service && "$UNIT_PATH" == /etc/systemd/system/twcn-pve-bootstrap.service \
        && "$BACKUP_ROOT" == /var/backups/twcn-pve-bootstrap ]] || die "卸载固定路径发生漂移"
}

validate_program_tree() {
    "$PYTHON_BIN" - "${1:-$INSTALL_ROOT}" "$BACKUP_ROOT" <<'PY'
import os, pathlib, re, stat, sys
root, backup = map(pathlib.Path, sys.argv[1:])
device = root.lstat().st_dev
if device != backup.stat().st_dev or os.path.ismount(root):
    raise SystemExit("程序目录跨文件系统或挂载点，保留现状")
for line in pathlib.Path("/proc/self/mountinfo").read_text().splitlines():
    mount = pathlib.Path(re.sub(r"\\([0-7]{3})", lambda m: chr(int(m[1], 8)), line.split()[4]))
    if mount == root or root in mount.parents or mount == backup or backup in mount.parents:
        raise SystemExit("程序或备份目录含挂载点，保留现状")
for directory, dirs, files in os.walk(root, followlinks=False):
    for path in [pathlib.Path(directory), *(pathlib.Path(directory) / name for name in dirs + files)]:
        info = path.lstat()
        if info.st_dev != device or os.path.ismount(path):
            raise SystemExit("程序目录含挂载点，保留现状")
        if info.st_uid != 0 or (not stat.S_ISLNK(info.st_mode) and info.st_mode & 0o022):
            raise SystemExit("程序目录非 root 独占写入，保留现状")
        if not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode)):
            raise SystemExit("程序目录含特殊文件，保留现状")
PY
}

acquire_maintenance_lock() {
    if [[ ! -e "$LOCK_FILE" && ! -L "$LOCK_FILE" ]]; then
        (set -o noclobber; : > "$LOCK_FILE") || die "锁文件创建失败"
    fi
    "$PYTHON_BIN" - "$LOCK_FILE" <<'PY'
import pathlib, stat, sys
path = pathlib.Path(sys.argv[1])
for parent in path.parents:
    info = parent.lstat()
    sticky_lock_directory = parent == path.parent and bool(info.st_mode & stat.S_ISVTX)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or (info.st_mode & 0o022 and not sticky_lock_directory):
        raise SystemExit("锁文件父目录不受 root 控制，保留现状")
info = path.lstat()
if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022 or info.st_nlink != 1:
    raise SystemExit("锁文件不受 root 独占控制，保留现状")
PY
    exec 9<>"$LOCK_FILE"
    [[ /proc/$$/fd/9 -ef "$LOCK_FILE" ]] || die "锁文件身份发生漂移"
    flock -n 9 || die "已有维护操作进行中"
}

move_program() {
    "$PYTHON_BIN" - "$1" "$2" <<'PY'
import os, sys
if os.path.lexists(sys.argv[2]):
    raise SystemExit("目标目录已经存在，保留现状")
os.rename(sys.argv[1], sys.argv[2])
PY
}

validate_uninstall_unit_content() {
    "$PYTHON_BIN" - "$1" <<'PY'
import hashlib, pathlib, sys
expected = "74b032242bd1751e488109a1ec07961c90600199e6c7dc3cb3aabb6f82acaac9"
if hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest() != expected:
    raise SystemExit("unit 不符合固定受管模板，保留现状")
PY
}

read_uninstall_state() {
    uninstall_active=$(systemctl show --property=ActiveState --value "$UNIT") || die "服务状态查询失败，保留现状"
    uninstall_enabled=$(systemctl show --property=UnitFileState --value "$UNIT") || die "启用状态查询失败，保留现状"
    [[ "$uninstall_active" == active || "$uninstall_active" == inactive ]] || die "服务状态发生漂移，保留现状"
    [[ "$uninstall_enabled" == enabled || "$uninstall_enabled" == disabled ]] || die "启用状态发生漂移，保留现状"
    service_was_active=0
    [[ "$uninstall_active" != active ]] || service_was_active=1
}

verify_uninstalled() {
    local load active enabled fragment dropins reload
    load=$(systemctl show --property=LoadState --value "$UNIT") || return 1
    active=$(systemctl show --property=ActiveState --value "$UNIT") || return 1
    enabled=$(systemctl show --property=UnitFileState --value "$UNIT") || return 1
    fragment=$(systemctl show --property=FragmentPath --value "$UNIT") || return 1
    dropins=$(systemctl show --property=DropInPaths --value "$UNIT") || return 1
    reload=$(systemctl show --property=NeedDaemonReload --value "$UNIT") || return 1
    [[ "$load" == not-found && "$active" == inactive && ( -z "$enabled" || "$enabled" == disabled ) \
        && -z "$fragment" && -z "$dropins" && "$reload" == no \
        && ! -e "$INSTALL_ROOT" && ! -L "$INSTALL_ROOT" && ! -e "$UNIT_PATH" && ! -L "$UNIT_PATH" ]]
}

backup_manifest() {
    "$PYTHON_BIN" - "$backup" "$1" <<'PY'
import hashlib, json, os, pathlib, stat, sys
base, action = pathlib.Path(sys.argv[1]), sys.argv[2]
records = {}
for root in (base / "program", base / "unit"):
    if not root.exists() or root.is_symlink():
        raise SystemExit("备份结构缺失")
    paths = [root]
    if root.is_dir():
        for directory, dirs, files in os.walk(root, followlinks=False):
            paths.extend(pathlib.Path(directory) / name for name in dirs + files)
    for path in paths:
        info = path.lstat()
        name = path.relative_to(base).as_posix()
        if stat.S_ISLNK(info.st_mode):
            records[name] = {"link": os.readlink(path)}
        elif stat.S_ISDIR(info.st_mode):
            records[name] = {"directory": True}
        elif stat.S_ISREG(info.st_mode):
            with path.open("rb") as stream:
                records[name] = {"sha256": hashlib.file_digest(stream, "sha256").hexdigest()}
        else:
            raise SystemExit("备份包含特殊文件")
        records[name].update(mode=stat.S_IMODE(info.st_mode), uid=info.st_uid, gid=info.st_gid)
manifest = base / "SHA256SUMS.json"
if action == "create":
    with manifest.open("x", encoding="utf-8", newline="\n") as stream:
        json.dump(records, stream, ensure_ascii=False, indent=2, sort_keys=True)
        stream.write("\n")
elif action != "check" or records != json.loads(manifest.read_text(encoding="utf-8")):
    raise SystemExit("备份 SHA256/结构校验失败")
PY
}

check_uninstall_backup() {
    local path
    [[ "$backup" == "$BACKUP_ROOT/"* && "$backup" != "$BACKUP_ROOT/" ]] || die "备份路径漂移"
    for path in "$BACKUP_ROOT" "$backup" "$backup/unit" "$backup/SHA256SUMS.json" "$backup/rollback.sh"; do
        reject_path_links "$path" || return 1
        require_root_controlled "$path" || return 1
    done
    [[ "$(stat -c %a "$backup")" == 700 ]] || die "备份目录权限漂移"
    validate_program_tree "$backup/program" || return 1
    backup_manifest check || return 1
    validate_uninstall_unit_content "$backup/unit" || return 1
    [[ -L "$backup/program/current" ]] || die "备份 current 不是受管链接"
    local target
    target=$(readlink -- "$backup/program/current") || die "备份链接查询失败"
    [[ "$target" == "$old_target" ]] || die "备份 current 发生漂移"
    cmp -s "$backup/unit" "$backup/program/releases/${old_target#"$INSTALL_ROOT/releases/"}/deploy/$UNIT" || die "备份 unit 不一致"
}

write_uninstall_rollback() {
    {
        printf '#!/usr/bin/env bash\nset -Eeuo pipefail\numask 077\n'
        local name
        for name in INSTALL_ROOT UNIT UNIT_PATH BACKUP_ROOT LOCK_FILE PYTHON_BIN old_target backup uninstall_active uninstall_enabled; do
            printf '%s=%q\n' "$name" "${!name}"
        done
        declare -f die validate_install_root reject_path_links require_root_controlled uninstall_preflight acquire_maintenance_lock move_program validate_program_tree validate_uninstall_unit_content backup_manifest check_uninstall_backup verify_uninstalled
        cat <<'ROLLBACK'
uninstall_preflight
acquire_maintenance_lock
check_uninstall_backup
case "${1:-check}" in
    check) printf '备份校验通过。\n' ;;
    restore)
        reject_path_links "$INSTALL_ROOT"
        reject_path_links "$UNIT_PATH"
        require_root_controlled "$(dirname -- "$INSTALL_ROOT")"
        require_root_controlled "$(dirname -- "$UNIT_PATH")"
        verify_uninstalled || die "已有安装或服务状态发生变化，保留现状"
        listeners=$(ss -H -ltnp 'sport = :8088') || die "端口查询失败，保留现状"
        [[ -z "$listeners" ]] || die "8088 端口存在其他进程，保留现状"
        "$PYTHON_BIN" - "$backup/program" "$INSTALL_ROOT" <<'PY'
import os, pathlib, sys
source, target = map(pathlib.Path, sys.argv[1:])
if source.stat().st_dev != target.parent.stat().st_dev:
    raise SystemExit("恢复路径跨文件系统，保留现状")
PY
        restore_program_moved=0; restore_unit_written=0
        restore_cleanup() {
            result=$?
            trap - EXIT
            if [[ "$result" -ne 0 ]]; then
                if [[ "$restore_unit_written" -eq 1 ]]; then
                    systemctl stop "$UNIT" || true
                    systemctl --quiet disable "$UNIT" || true
                    rm -- "$UNIT_PATH" || true
                fi
                if [[ "$restore_program_moved" -eq 1 && ! -e "$backup/program" ]]; then
                    move_program "$INSTALL_ROOT" "$backup/program" || true
                fi
                systemctl daemon-reload || true
                if verify_uninstalled && check_uninstall_backup; then
                    printf '恢复失败，备份已保留；可核验后重试。\n' >&2
                else printf '恢复失败，程序与服务状态需人工核对。\n' >&2; fi
            fi
            exit "$result"
        }
        trap restore_cleanup EXIT
        move_program "$backup/program" "$INSTALL_ROOT"
        restore_program_moved=1
        restore_unit_written=1
        cp -p -- "$backup/unit" "$UNIT_PATH"
        systemctl daemon-reload
        if [[ "$uninstall_enabled" == enabled ]]; then systemctl --quiet enable "$UNIT"; else systemctl --quiet disable "$UNIT"; fi
        if [[ "$uninstall_active" == active ]]; then systemctl start "$UNIT"; fi
        active=$(systemctl show --property=ActiveState --value "$UNIT")
        enabled=$(systemctl show --property=UnitFileState --value "$UNIT")
        [[ "$active" == "$uninstall_active" && "$enabled" == "$uninstall_enabled" ]] || die "恢复状态需人工核对"
        trap - EXIT
        printf '程序与服务状态已恢复，数据保持原位。\n'
        ;;
    *) die "用法：rollback.sh [check|restore]" ;;
esac
ROLLBACK
    } > "$backup/rollback.sh"
    chmod 0700 "$backup/rollback.sh"
}

uninstall_bootstrap() {
    uninstall_preflight
    local path
    for path in "$INSTALL_ROOT" "$INSTALL_ROOT/releases" "$UNIT_PATH" "$BACKUP_ROOT"; do
        reject_path_links "$path"
        require_root_controlled "$path"
    done
    acquire_maintenance_lock
    if [[ ! -e "$INSTALL_ROOT" && ! -e "$UNIT_PATH" ]]; then
        verify_uninstalled || die "服务状态发生漂移，保留现状"
        printf '已卸载。\n'
        return
    fi
    [[ -d "$INSTALL_ROOT" && -f "$UNIT_PATH" && -L "$INSTALL_ROOT/current" ]] || die "安装结构发生漂移，保留现状"
    old_target=$(readlink -f -- "$INSTALL_ROOT/current") || die "current 查询失败"
    [[ "$old_target" == "$INSTALL_ROOT/releases/"* && -d "$old_target" ]] || die "current 不在本模块 releases，保留现状"
    reject_path_links "$old_target"
    require_root_controlled "$old_target"
    read_uninstall_state
    validate_managed_unit
    validate_uninstall_unit_content "$UNIT_PATH"
    validate_service_listener
    mkdir -p -m 0700 -- "$BACKUP_ROOT"
    require_root_controlled "$BACKUP_ROOT"
    validate_program_tree
    backup=$(mktemp -d "$BACKUP_ROOT/uninstall.XXXXXXXX")
    chmod 0700 "$backup"
    cp -p -- "$UNIT_PATH" "$backup/unit"
    changed=0; program_moved=0; unit_removed=0; completed=0
    uninstall_cleanup() {
        local result=$? restored=1 active enabled
        trap - EXIT
        if [[ "$result" -ne 0 && "$changed" -eq 1 && "$completed" -eq 0 ]]; then
            if [[ "$program_moved" -eq 1 ]]; then
                if [[ ! -e "$INSTALL_ROOT" && ! -L "$INSTALL_ROOT" ]]; then
                    move_program "$backup/program" "$INSTALL_ROOT" || restored=0
                else restored=0; fi
            fi
            if [[ "$unit_removed" -eq 1 ]]; then
                if [[ ! -e "$UNIT_PATH" && ! -L "$UNIT_PATH" ]]; then cp -p -- "$backup/unit" "$UNIT_PATH" || restored=0; else restored=0; fi
            fi
            systemctl daemon-reload || restored=0
            if [[ "$uninstall_enabled" == enabled ]]; then systemctl --quiet enable "$UNIT" || restored=0; else systemctl --quiet disable "$UNIT" || restored=0; fi
            if [[ "$uninstall_active" == active ]]; then systemctl start "$UNIT" || restored=0; else systemctl stop "$UNIT" || restored=0; fi
            active=$(systemctl show --property=ActiveState --value "$UNIT") || restored=0
            enabled=$(systemctl show --property=UnitFileState --value "$UNIT") || restored=0
            [[ "$active" == "$uninstall_active" && "$enabled" == "$uninstall_enabled" && -d "$INSTALL_ROOT" ]] || restored=0
            cmp -s "$UNIT_PATH" "$backup/unit" || restored=0
            if [[ "$restored" -eq 1 ]]; then printf '卸载失败，原程序与服务状态已恢复。\n' >&2
            else printf '卸载失败，恢复未完整确认；请核对备份：%s\n' "$backup" >&2; fi
        fi
        exit "$result"
    }
    trap uninstall_cleanup EXIT
    local active enabled
    active=$(systemctl show --property=ActiveState --value "$UNIT")
    enabled=$(systemctl show --property=UnitFileState --value "$UNIT")
    [[ "$active" == "$uninstall_active" && "$enabled" == "$uninstall_enabled" ]] || die "服务状态已变化，保留现状"
    validate_managed_unit
    validate_uninstall_unit_content "$UNIT_PATH"
    validate_service_listener
    changed=1
    if [[ "$uninstall_active" == active ]]; then systemctl stop "$UNIT"; fi
    systemctl --quiet disable "$UNIT"
    local listeners
    active=$(systemctl show --property=ActiveState --value "$UNIT")
    enabled=$(systemctl show --property=UnitFileState --value "$UNIT")
    [[ "$active" == inactive && "$enabled" == disabled ]] || die "服务未停止或未禁用"
    listeners=$(ss -H -ltnp "sport = :$PORT") || die "端口查询失败"
    [[ -z "$listeners" ]] || die "端口仍被占用，保留进程"
    move_program "$INSTALL_ROOT" "$backup/program"
    program_moved=1
    backup_manifest create
    write_uninstall_rollback
    check_uninstall_backup
    rm -- "$UNIT_PATH"
    unit_removed=1
    systemctl daemon-reload
    verify_uninstalled || die "卸载状态核验失败"
    completed=1
    trap - EXIT
    printf '已卸载；配置、证书和上传数据保留。\n备份：%s\n' "$backup"
}

select_action() {
    local choice
    printf '1 安装/更新\n2 卸载\n0 退出\n请选择：' >&2
    read -r choice || die "未读取到选项"
    case "$choice" in
        1) install_bootstrap ;;
        2) uninstall_bootstrap ;;
        0) return 0 ;;
        *) die "请选择 1、2 或 0" ;;
    esac
}

main() {
    [[ "$#" -le 1 ]] || die "用法：install.sh [--install|--uninstall]"
    case "${1:-}" in
        --install) install_bootstrap ;;
        --uninstall) uninstall_bootstrap ;;
        '') if [[ -t 0 ]]; then select_action; else install_bootstrap; fi ;;
        *) die "用法：install.sh [--install|--uninstall]" ;;
    esac
}

if [[ "${BOOTSTRAP_LIBRARY_ONLY:-0}" != 1 ]]; then
    main "$@"
fi
