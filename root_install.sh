#!/system/bin/sh
# Surfing 免模块一键安装：直接用 root 权限安装，不经过 Magisk / KernelSU / APatch 管理器
#
# 一键模式（推荐）：用 MT 管理器以 root 执行本脚本，或在终端执行
#   su -c sh /sdcard/Download/root_install.sh
# 自动从官方仓库下载最新 release，按音量键（或输入数字）选择选项。
#
# 命令行模式：
#   su -c sh root_install.sh /sdcard/Download/Surfing_v7.8.4_release.zip [选项]
#   选项：
#     --hosts      挂载 box_bll/clash/etc/hosts 到 /system/etc/hosts（会留下 bind mount 痕迹，默认不挂载）
#     --app        安装 SurfingTile App（App 内的启停开关依赖模块目录，免模块方式下不可用）
#     --no-start   安装后不立即启动（开机仍会自动启动，可用 surfing start 启动）
#     --keep-config 更新时保留现有 config.yaml（新版默认配置另存为 config.yaml.new）

REPO="GitMetaio/Surfing"
# 直连 GitHub 失败时依次尝试的加速镜像（下载后会用官方 sha256 校验）
MIRRORS="https://gh-proxy.com/ https://ghfast.top/"

BOX_BLL_PATH="/data/adb/box_bll"
BIN_PATH="$BOX_BLL_PATH/bin"
SCRIPTS_PATH="$BOX_BLL_PATH/scripts"
SWITCH_DIR="$BOX_BLL_PATH/switch"
VERSION_FILE="$BOX_BLL_PATH/.root_version"
CONFIG_FILE="$BOX_BLL_PATH/clash/config.yaml"
BACKUP_FILE="$BOX_BLL_PATH/clash/proxies/subscribe_urls_backup.txt"
HOSTS_PATH="$BOX_BLL_PATH/clash/etc"
HOSTS_FILE="$HOSTS_PATH/hosts"
STAGE="/data/local/tmp/surfing_root_stage"
DL_TMP="/data/local/tmp/surfing_root_dl"
KEY_TIMEOUT=15

MOUNT_HOSTS=false
INSTALL_APP=false
START_NOW=true
KEEP_CONFIG=false
SRC=""

for arg in "$@"; do
  case "$arg" in
    --hosts) MOUNT_HOSTS=true ;;
    --app) INSTALL_APP=true ;;
    --no-start) START_NOW=false ;;
    --keep-config) KEEP_CONFIG=true ;;
    -*) echo "未知选项: $arg"; exit 1 ;;
    *) SRC="$arg" ;;
  esac
done

SCRIPT_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
INTERACTIVE=false
if [ -z "$SRC" ]; then
  if [ -d "$SCRIPT_DIR/box_bll" ]; then SRC="$SCRIPT_DIR"; else INTERACTIVE=true; fi
fi

ui_print() { echo "$@"; }
abort() { echo ""; echo "❌ 错误: $*"; rm -rf "$STAGE" "$DL_TMP"; exit 1; }

# ====================== 交互 ======================
if [ -t 0 ]; then INPUT_MODE=tty; else INPUT_MODE=key; fi

# 读取一次音量键，输出 UP / DOWN，超时输出空
read_key() {
  timeout "$1" getevent -ql 2>/dev/null | awk '
    $3 == "KEY_VOLUMEUP" && $4 == "DOWN" { print "UP"; exit }
    $3 == "KEY_VOLUMEDOWN" && $4 == "DOWN" { print "DOWN"; exit }'
}

# ask_yn "问题" y|n  → 返回 0 表示“是”
ask_yn() {
  q="$1"; def="$2"
  [ "$def" = y ] && def_txt="是" || def_txt="否"
  ui_print ""
  ui_print "❓ $q"
  if [ "$INPUT_MODE" = tty ]; then
    printf '   输入 1=是  2=否  [回车默认: %s]: ' "$def_txt"
    read -r ans
    case "$ans" in
      1|y|Y) return 0 ;;
      2|n|N) return 1 ;;
      *) [ "$def" = y ]; return ;;
    esac
  fi
  ui_print "   [音量+] 是      [音量-] 否      (${KEY_TIMEOUT} 秒无操作默认: $def_txt)"
  k=$(read_key "$KEY_TIMEOUT")
  sleep 0.5
  case "$k" in
    UP) ui_print "   → 是"; return 0 ;;
    DOWN) ui_print "   → 否"; return 1 ;;
    *) ui_print "   → 超时，使用默认: $def_txt"; [ "$def" = y ] ;;
  esac
}

# ====================== 下载 ======================
CURL_CANDIDATES=""
BB_CANDIDATES=""
init_downloaders() {
  c=$(command -v curl 2>/dev/null); [ -n "$c" ] && CURL_CANDIDATES="$c"
  [ -x "$BIN_PATH/curl" ] && CURL_CANDIDATES="$CURL_CANDIDATES $BIN_PATH/curl"
  for b in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox "$BIN_PATH/busybox"; do
    [ -x "$b" ] && BB_CANDIDATES="$BB_CANDIDATES $b"
  done
  [ -n "$CURL_CANDIDATES$BB_CANDIDATES" ] || abort "找不到可用的下载工具（curl / busybox wget），请手动下载 release zip 后用命令行模式安装"
}

# http_get URL 输出文件
http_get() {
  for c in $CURL_CANDIDATES; do
    "$c" -fsSL --connect-timeout 10 --retry 2 -m 900 -o "$2" "$1" 2>/dev/null && [ -s "$2" ] && return 0
  done
  for b in $BB_CANDIDATES; do
    "$b" wget -q -T 20 -O "$2" "$1" 2>/dev/null && [ -s "$2" ] && return 0
  done
  rm -f "$2"
  return 1
}

LATEST_VER=""; ZIP_URL=""; ZIP_SHA256=""
fetch_latest_info() {
  json="$DL_TMP/latest.json"
  ui_print "🔎 正在获取最新版本信息..."
  if http_get "https://api.github.com/repos/$REPO/releases/latest" "$json"; then
    LATEST_VER=$(grep -oE '"tag_name": *"[^"]*"' "$json" | head -n 1 | cut -d'"' -f4)
    # 每个资产里 digest 在 browser_download_url 之前，取 *_release.zip 对应的那一对
    eval "$(grep -oE '"digest": *"sha256:[0-9a-f]+"|"browser_download_url": *"[^"]*"' "$json" | awk -F'"' '
      /"digest"/ { d = substr($4, 8) }
      /"browser_download_url"/ {
        if ($4 ~ /_release\.zip$/) { printf "ZIP_URL=\"%s\"; ZIP_SHA256=\"%s\"\n", $4, d; exit }
        d = ""
      }')"
  fi
  if [ -z "$ZIP_URL" ]; then
    # GitHub API 不可用时，读取仓库中的更新描述文件（无法获取校验值）
    for prefix in "" $MIRRORS; do
      if http_get "${prefix}https://raw.githubusercontent.com/$REPO/main/Surfing.json" "$DL_TMP/Surfing.json"; then
        LATEST_VER=$(grep -oE '"version": *"[^"]*"' "$DL_TMP/Surfing.json" | cut -d'"' -f4)
        ZIP_URL=$(grep -oE '"zipUrl": *"[^"]*"' "$DL_TMP/Surfing.json" | cut -d'"' -f4)
        ZIP_SHA256=""
        [ -n "$ZIP_URL" ] && break
      fi
    done
  fi
  [ -n "$ZIP_URL" ] || return 1
  ui_print "   最新版本: $LATEST_VER"
  return 0
}

verify_zip() {
  if [ -n "$ZIP_SHA256" ]; then
    actual=$(sha256sum "$1" | cut -d' ' -f1)
    [ "$actual" = "$ZIP_SHA256" ] || { ui_print "   ⚠️ 校验失败（sha256 不一致），换下一个下载源"; return 1; }
    ui_print "   ✅ sha256 校验通过"
  fi
  unzip -tq "$1" >/dev/null 2>&1 || { ui_print "   ⚠️ 压缩包损坏，换下一个下载源"; return 1; }
  return 0
}

download_release() {
  zip="$DL_TMP/$(basename "$ZIP_URL")"
  for prefix in "" $MIRRORS; do
    if [ -z "$prefix" ]; then ui_print "⬇️  正在从 GitHub 下载（文件较大，请耐心等待）..."
    else ui_print "⬇️  正在通过镜像 $prefix 下载..."; fi
    if http_get "${prefix}${ZIP_URL}" "$zip" && verify_zip "$zip"; then
      SRC="$zip"
      return 0
    fi
    rm -f "$zip"
  done
  return 1
}

# 下载失败时，使用 Download 目录或脚本目录中已有的 release zip
find_local_zip() {
  ls -t "$SCRIPT_DIR"/Surfing_*_release.zip /sdcard/Download/Surfing_*_release.zip 2>/dev/null | head -n 1
}

# ====================== 安装辅助 ======================
init_busybox_toolchain() { chmod 755 "$BIN_PATH/busybox" && (cd "$BIN_PATH" && find . -type l -delete && ./busybox --install -s .); }

set_perm_recursive() {
  # $1 路径 $2 uid $3 gid $4 目录权限 $5 文件权限
  chown -R "$2:$3" "$1"
  find "$1" -type d -exec chmod "$4" {} +
  find "$1" -type f -exec chmod "$5" {} +
}

# 原版用 /data/adb/modules/Surfing/disable 作为服务开关，这里改为 $SWITCH_DIR/disable
patch_module_dir() {
  f="$1"
  [ -f "$f" ] || return 0
  sed -i \
    -e '/magisk -v | grep -q lite && module_dir=/d' \
    -e "s|^module_dir=\"/data/adb/modules/Surfing\"|module_dir=\"$SWITCH_DIR\"|" \
    -e '/^BASE_MODULES_DIR=/d' \
    -e '/BASE_MODULES_DIR="\/data\/adb\/lite_modules"/d' \
    -e "s|^SURFING_DIR=\"\${BASE_MODULES_DIR}/Surfing\"|SURFING_DIR=\"$SWITCH_DIR\"|" \
    "$f"
  if grep -qE '/data/adb/(lite_)?modules|BASE_MODULES_DIR' "$f"; then
    abort "上游脚本结构已变化，无法自动去模块化: ${f#$STAGE/}"
  fi
}

extract_subscribe_urls() {
  if [ -f "$CONFIG_FILE" ]; then
    mkdir -p "$(dirname "$BACKUP_FILE")"
    sed -n '/# 订阅地址相关/,/profile:.*↑/p' "$CONFIG_FILE" > "$BACKUP_FILE"
    if [ -s "$BACKUP_FILE" ]; then
      ui_print "已备份订阅配置."
    else
      ui_print "未找到订阅块.将使用默认值."
    fi
  fi
}

restore_subscribe_urls() {
  if [ -f "$BACKUP_FILE" ] && [ -s "$BACKUP_FILE" ]; then
    awk -v backup="$BACKUP_FILE" '
      BEGIN { skip = 0 }
      /# 订阅地址相关/ {
        skip = 1
        while ((getline < backup) > 0) { print }
        close(backup)
        next
      }
      /profile:.*↑/ {
        skip = 0
        next
      }
      !skip { print }
    ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    ui_print "已恢复订阅配置."
  fi
}

migrate_box_config() {
  OLD_CONFIG="$SCRIPTS_PATH/box.config.bak"; NEW_CONFIG="$SCRIPTS_PATH/box.config"
  [ -f "$OLD_CONFIG" ] || return 0
  ui_print "正在迁移网络服务控制设置..."
  TMP_CONFIG="${NEW_CONFIG}.tmp"; cp -f "$NEW_CONFIG" "$TMP_CONFIG"
  VARS="enable_network_service_control bypass_via_iptables enable_cellular_proxy enable_wifi_proxy enable_ssid_filter enable_mac_filter use_wifi_list_mode blacklist_wifi_macs whitelist_wifi_macs blacklist_wifi_ssids whitelist_wifi_ssids ap_list gid_list user_packages_list proxy_mode proxy_method ipv6 intranet intranet6"
  for var in $VARS; do
    val=$(grep "^${var}=" "$OLD_CONFIG" | cut -d'=' -f2-)
    [ -n "$val" ] && sed "s@^${var}=.*@${var}=${val}@" "$TMP_CONFIG" > "${TMP_CONFIG}.bak" && mv -f "${TMP_CONFIG}.bak" "$TMP_CONFIG"
  done
  mv -f "$TMP_CONFIG" "$NEW_CONFIG"
}

kill_watchers() {
  for pid in $(pidof inotifyd); do
    grep -qE "box.inotify|net.inotify|ctr.inotify" "/proc/$pid/cmdline" 2>/dev/null && kill "$pid"
  done
}

stop_running_service() {
  [ -x "$SCRIPTS_PATH/box.iptables" ] && "$SCRIPTS_PATH/box.iptables" disable >/dev/null 2>&1
  [ -x "$SCRIPTS_PATH/box.service" ] && "$SCRIPTS_PATH/box.service" stop >/dev/null 2>&1
}

install_surfingtile_apk() {
  [ -f "$STAGE/SurfingTile.zip" ] || { ui_print "安装包中没有 SurfingTile，跳过."; return 0; }
  APK_TMP="/data/local/tmp/com.github.surfing.apk"
  unzip -o "$STAGE/SurfingTile.zip" "com.github.surfing.apk" -d /data/local/tmp >/dev/null 2>&1
  if [ -f "$APK_TMP" ]; then
    ui_print "正在安装 SurfingTile APK..."
    pm install "$APK_TMP"
    rm -f "$APK_TMP"
  fi
}

# 免模块版专用的启停 / 卸载命令（原版 release 中没有，安装时生成）
write_helper_scripts() {
  cat > "$SCRIPTS_PATH/surfing" <<'EOF'
#!/system/bin/sh
# 免模块安装的服务开关：surfing start|stop|restart|status
# 通过 switch/disable 文件控制，与模块版在管理器中开关模块的效果相同
export PATH="/data/adb/box_bll/bin:$PATH"

scripts=$(realpath "$0")
scripts_dir=$(dirname "${scripts}")
. "${scripts_dir}/box.config"

switch_dir="${box_path}/switch"
disable_file="${switch_dir}/disable"
mkdir -p "${switch_dir}" "${run_path}"

watching() {
  for pid in $(pidof inotifyd); do
    grep -q "box.inotify" "/proc/$pid/cmdline" 2>/dev/null && \
      tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q "${switch_dir}" && return 0
  done
  return 1
}

is_running() {
  [ -f "${pid_file}" ] && kill -0 "$(cat "${pid_file}")" 2>/dev/null
}

direct_start() {
  "${scripts_dir}/box.service" start >> "${run_path}/run.log" 2>> "${run_path}/run_error.log" && \
    "${scripts_dir}/box.iptables" enable >> "${run_path}/run.log" 2>> "${run_path}/run_error.log"
}

direct_stop() {
  "${scripts_dir}/box.service" stop >> "${run_path}/run.log" 2>> "${run_path}/run_error.log"
  "${scripts_dir}/box.iptables" disable >> "${run_path}/run.log" 2>> "${run_path}/run_error.log"
}

# 开关文件状态有变化时交给 box.inotify 处理，否则直接调用
do_start() {
  if [ -f "${disable_file}" ] && watching; then
    rm -f "${disable_file}"
  else
    rm -f "${disable_file}"
    is_running || direct_start
  fi
}

do_stop() {
  if [ ! -f "${disable_file}" ] && watching; then
    touch "${disable_file}"
  else
    touch "${disable_file}"
    direct_stop
  fi
}

wait_state() {
  n=0
  while [ $n -lt 15 ]; do
    if [ "$1" = up ]; then is_running && return 0; else is_running || return 0; fi
    sleep 1; n=$((n + 1))
  done
  return 1
}

case "$1" in
  start)
    do_start
    if wait_state up; then echo "已启动"; else echo "启动失败，查看 ${run_path}/run_error.log"; exit 1; fi
    ;;
  stop)
    do_stop
    if wait_state down; then echo "已停止"; else echo "停止超时"; exit 1; fi
    ;;
  restart)
    do_stop; wait_state down; sleep 1
    do_start
    if wait_state up; then echo "已重启"; else echo "启动失败，查看 ${run_path}/run_error.log"; exit 1; fi
    ;;
  status)
    if is_running; then echo "运行中 (pid $(cat "${pid_file}"))"; else echo "未运行"; fi
    [ -f "${disable_file}" ] && echo "开机自启: 已关闭 (存在 ${disable_file})" || echo "开机自启: 开启"
    watching && echo "开关监听: 正常" || echo "开关监听: 未运行"
    ;;
  *)
    echo "用法: $0 start|stop|restart|status"
    exit 1
    ;;
esac
EOF

  cat > "$SCRIPTS_PATH/root_uninstall.sh" <<'EOF'
#!/system/bin/sh
# Surfing 免模块卸载：su -c sh /data/adb/box_bll/scripts/root_uninstall.sh [--app]
[ "$(id -u)" = 0 ] || { echo "需要 root 权限"; exit 1; }

BOX_BLL_PATH="/data/adb/box_bll"
SCRIPTS_PATH="$BOX_BLL_PATH/scripts"

[ -x "$SCRIPTS_PATH/box.iptables" ] && "$SCRIPTS_PATH/box.iptables" disable >/dev/null 2>&1
[ -x "$SCRIPTS_PATH/box.service" ] && "$SCRIPTS_PATH/box.service" stop >/dev/null 2>&1

for pid in $(pidof inotifyd); do
  grep -qE "box.inotify|net.inotify|ctr.inotify" "/proc/$pid/cmdline" 2>/dev/null && kill "$pid"
done

umount -l /system/etc/hosts >/dev/null 2>&1
rm -f /data/adb/service.d/Surfing_service.sh /data/adb/ksu/service.d/Surfing_service.sh
rm -rf "$BOX_BLL_PATH"

if [ "$1" = "--app" ]; then
  pm uninstall com.github.surfing >/dev/null 2>&1
fi

echo "已卸载 Surfing（免模块版）"
EOF
}

# ====================== 安装 ======================
do_install() {
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  if [ -f "$SRC" ]; then
    command -v unzip >/dev/null 2>&1 || abort "系统缺少 unzip 命令，请先在电脑上解压后再执行"
    unzip -qo "$SRC" -x 'META-INF/*' -d "$STAGE" || abort "解压失败: $SRC"
  elif [ -d "$SRC/box_bll" ]; then
    cp -rf "$SRC/." "$STAGE/"
  else
    abort "找不到安装文件: $SRC"
  fi
  [ -d "$STAGE/box_bll" ] && [ -f "$STAGE/Surfing_service.sh" ] || abort "安装包内容不完整"
  [ -f "$STAGE/box_bll/bin/clash" ] || abort "安装包缺少内核 box_bll/bin/clash，请使用 release 构建产物"

  VERSION=$(grep '^version=' "$STAGE/module.prop" 2>/dev/null | cut -d'=' -f2-)
  ui_print ""
  ui_print "📦 正在安装 Surfing ${VERSION}"

  patch_module_dir "$STAGE/box_bll/scripts/start.sh"
  patch_module_dir "$STAGE/box_bll/scripts/ctr.inotify"
  patch_module_dir "$STAGE/Surfing_service.sh"

  service_dir="/data/adb/service.d"
  [ ! -d "$service_dir" ] && [ -d /data/adb/ksu/service.d ] && service_dir="/data/adb/ksu/service.d"
  mkdir -p "$service_dir"

  kill_watchers
  if [ -d "$SCRIPTS_PATH" ]; then
    ui_print "检测到已有安装，正在更新..."
    stop_running_service
    export PATH="$BIN_PATH:$PATH"

    cp -f "$STAGE/box_bll/bin/busybox" "$BIN_PATH/busybox" && init_busybox_toolchain
    cp -f "$STAGE/box_bll/bin/curl" "$BIN_PATH/curl" 2>/dev/null
    cp -f "$STAGE/box_bll/bin/clash" "$BIN_PATH/clash"
    cp -f "$CONFIG_FILE" "$CONFIG_FILE.bak"
    if [ "$KEEP_CONFIG" = true ]; then
      cp -f "$STAGE/box_bll/clash/config.yaml" "$CONFIG_FILE.new"
      ui_print "保留现有 config.yaml（新版默认配置: config.yaml.new）"
    else
      extract_subscribe_urls
      cp -f "$STAGE/box_bll/clash/config.yaml" "$BOX_BLL_PATH/clash/"
    fi

    cp -f "$SCRIPTS_PATH/box.config" "$SCRIPTS_PATH/box.config.bak"
    cp -f "$STAGE/box_bll/scripts/"* "$SCRIPTS_PATH/"
    migrate_box_config
    [ "$KEEP_CONFIG" = true ] || restore_subscribe_urls
    ui_print "已备份: config.yaml.bak / box.config.bak"
  else
    cp -rf "$STAGE/box_bll" "$(dirname "$BOX_BLL_PATH")/"
    init_busybox_toolchain
  fi
  write_helper_scripts

  mkdir -p "$HOSTS_PATH" "$SWITCH_DIR"
  if [ "$MOUNT_HOSTS" = true ]; then
    [ -f "$HOSTS_FILE" ] || cp -f "$STAGE/box_bll/clash/etc/hosts" "$HOSTS_FILE"
    ui_print "将挂载 hosts 文件."
  else
    umount -l /system/etc/hosts >/dev/null 2>&1
    rm -f "$HOSTS_FILE"
  fi

  cp -f "$STAGE/Surfing_service.sh" "$service_dir/Surfing_service.sh"
  echo "$VERSION" > "$VERSION_FILE"

  set_perm_recursive "$BOX_BLL_PATH" 0 3005 0755 0644
  set_perm_recursive "$SCRIPTS_PATH" 0 3005 0755 0700
  set_perm_recursive "$BIN_PATH" 0 0 0755 0755
  set_perm_recursive "$HOSTS_PATH" 0 0 0755 0644
  chown 0:0 "$service_dir/Surfing_service.sh"
  chmod 0700 "$service_dir/Surfing_service.sh"
  chmod ugo+x "$SCRIPTS_PATH/"*

  [ "$INSTALL_APP" = true ] && install_surfingtile_apk
  rm -rf "$STAGE" "$DL_TMP"

  if [ "$START_NOW" = true ]; then
    rm -f "$SWITCH_DIR/disable"
    ui_print "🚀 正在启动服务..."
  else
    touch "$SWITCH_DIR/disable"
  fi
  # 与开机流程相同：由 service.d 脚本拉起服务和监听进程
  nohup sh "$service_dir/Surfing_service.sh" >/dev/null 2>&1 &

  ui_print ""
  ui_print "================================================"
  ui_print " ✅ 安装完成"
  ui_print "================================================"
  ui_print " 配置文件: $CONFIG_FILE"
  ui_print "   （首次安装请在其中填写订阅地址，然后重启服务）"
  ui_print " 面板:     http://127.0.0.1:9090/ui"
  ui_print " 启停:     su -c $SCRIPTS_PATH/surfing start|stop|restart|status"
  ui_print " 卸载:     再次运行本脚本，或"
  ui_print "           su -c sh $SCRIPTS_PATH/root_uninstall.sh"
  [ "$START_NOW" = true ] || ui_print " 服务未启动，启动请执行上面的 surfing start"
  ui_print "================================================"
}

do_uninstall() {
  ui_print ""
  ui_print "🗑️  正在卸载..."
  stop_running_service
  kill_watchers
  umount -l /system/etc/hosts >/dev/null 2>&1
  rm -f /data/adb/service.d/Surfing_service.sh /data/adb/ksu/service.d/Surfing_service.sh
  rm -rf "$BOX_BLL_PATH"
  if pm path com.github.surfing >/dev/null 2>&1; then
    ask_yn "同时卸载 SurfingTile App？" y && pm uninstall com.github.surfing >/dev/null 2>&1
  fi
  ui_print ""
  ui_print "✅ 已卸载 Surfing（免模块版）"
}

# ====================== 主流程 ======================
[ "$(id -u)" = 0 ] || abort "需要 root 权限（MT 管理器请勾选「使用 Root 权限执行」）"

for d in /data/adb/modules/Surfing /data/adb/lite_modules/Surfing; do
  [ -d "$d" ] && abort "检测到已安装模块版 Surfing ($d)，请先在管理器中卸载模块并重启"
done

if [ "$INTERACTIVE" = false ]; then
  do_install
  exit 0
fi

INSTALLED_VER=""
if [ -d "$SCRIPTS_PATH" ]; then
  INSTALLED_VER=$(cat "$VERSION_FILE" 2>/dev/null)
  [ -n "$INSTALLED_VER" ] || INSTALLED_VER="未知版本"
fi

ui_print "================================================"
ui_print "        Surfing 免模块一键安装"
ui_print "   不经过 Magisk / KernelSU / APatch 模块"
ui_print "================================================"
if [ -n "$INSTALLED_VER" ]; then
  ui_print " 当前状态: 已安装 ($INSTALLED_VER)"
else
  ui_print " 当前状态: 未安装"
fi
if [ "$INPUT_MODE" = key ]; then
  ui_print " 操作方式: 按 [音量+] 选是，按 [音量-] 选否"
else
  ui_print " 操作方式: 输入数字后回车"
fi
ui_print "================================================"

if [ -n "$INSTALLED_VER" ]; then
  if ask_yn "更新 / 重新安装 Surfing？（保留订阅和设置）" y; then
    :
  elif ask_yn "卸载 Surfing？" n; then
    do_uninstall
    exit 0
  else
    ui_print ""; ui_print "已取消."; exit 0
  fi
else
  ask_yn "安装 Surfing？" y || { ui_print ""; ui_print "已取消."; exit 0; }
fi

rm -rf "$DL_TMP"; mkdir -p "$DL_TMP"
USED_LOCAL=false
init_downloaders
ui_print ""
if fetch_latest_info && download_release; then
  :
else
  LOCAL_ZIP=$(find_local_zip)
  [ -n "$LOCAL_ZIP" ] || abort "下载失败，请检查网络；或手动下载 release zip 放到 Download 目录后重新运行"
  ask_yn "下载失败，使用本地文件 $(basename "$LOCAL_ZIP")？" y || abort "已取消"
  SRC="$LOCAL_ZIP"
  USED_LOCAL=true
fi
if [ -z "$ZIP_SHA256" ] && [ "$USED_LOCAL" = false ]; then
  ask_yn "⚠️ 无法获取官方校验值，安装包未经校验，仍要继续？" n || abort "已取消"
fi

if [ -n "$INSTALLED_VER" ] && [ -f "$CONFIG_FILE" ]; then
  if ask_yn "保留当前的 config.yaml？（选“否”则换成新版默认配置，只保留订阅地址）" y; then
    KEEP_CONFIG=true
  fi
fi
if ask_yn "安装 SurfingTile App？（快捷开关/面板 App；会多一个可被检测的应用，且 App 内启停开关在免模块方式下无效）" n; then
  INSTALL_APP=true
fi
if ask_yn "挂载 hosts 文件到系统？（会留下挂载痕迹，一般不需要）" n; then
  MOUNT_HOSTS=true
fi
if ! ask_yn "安装后立即启动服务？" y; then
  START_NOW=false
fi

do_install
