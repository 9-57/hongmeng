#!/usr/bin/env bash
# 一键：构建 + 本地签名 + 安装到设备 + 启动。替代 IDE 的 Run 按钮。
#
# 设备选择：
#   不指定          hdc 里只连了一台就用它；一台都没有则尝试拉起模拟器；多台则报错让你指定
#   --device <序列号>  指定设备（如 127.0.0.1:5555），也可用环境变量 HDC_TARGET
#   NO_EMULATOR=1  没设备时不自动拉起模拟器
#
# 用法： bash tools/run.sh [--device 127.0.0.1:5555]
set -euo pipefail

# DevEco 安装位置在不同机器/不同时期可能不一样（本机是 "D:/DevEco studio"，
# 早期文档写的是 "D:/deveco-studio/DevEco Studio"）。按候选顺序探测，
# 项目拷到别的电脑后也不会因为路径不同直接跑不起来。
resolve_deveco() {
  for c in "${DEVECO_HOME:-}" "D:/DevEco studio" "D:/deveco-studio/DevEco Studio" \
           "D:/HarmonyOS/DevEco Studio6.0.1/DevEco Studio" "C:/Program Files/Huawei/DevEco Studio"; do
    if [ -n "$c" ] && [ -d "$c/sdk" ]; then printf '%s' "$c"; return 0; fi
  done
  echo "找不到 DevEco Studio 安装目录，请设置 DEVECO_HOME（例如 D:/DevEco studio）" >&2
  return 1
}

DEVECO_HOME="$(resolve_deveco)"
HDC="$DEVECO_HOME/sdk/default/openharmony/toolchains/hdc.exe"
EMULATOR="$DEVECO_HOME/tools/emulator/Emulator.exe"
EMU_NAME="${EMU_NAME:-Mate 80 Pro Max}"
# 模拟器实例目录跟着当前用户走，不能写死成别人的用户目录
EMU_PATH="${EMU_PATH:-C:/Users/${USERNAME}/AppData/Local/Huawei/Emulator/deployed}"
BUNDLE="com.example.harmony03"
ABILITY="EntryAbility"
HDC_TARGET="${HDC_TARGET:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    -d|--device) HDC_TARGET="$2"; shift 2 ;;
    -h|--help) sed -n "2,9p" "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export MSYS2_ARG_CONV_EXCL="*"

list_targets() {
  "$HDC" list targets 2>/dev/null | tr -d "\r" | sed "/^\[Empty\]$/d" | sed "/^$/d"
}

# ---- 1. 选定设备 ----
if [ -z "$HDC_TARGET" ]; then
  mapfile -t TS < <(list_targets)
  if [ "${#TS[@]}" -eq 0 ]; then
    if [ "${NO_EMULATOR:-0}" = "1" ]; then
      echo "没有连接的设备，且已设置 NO_EMULATOR=1。" >&2
      exit 1
    fi
    echo "[0/4] 没有设备，启动模拟器 $EMU_NAME（约 60~120 秒）"
    "$EMULATOR" -hvd "$EMU_NAME" -path "$EMU_PATH" >/dev/null 2>&1 &
    for _ in $(seq 1 90); do
      sleep 2
      mapfile -t TS < <(list_targets)
      [ "${#TS[@]}" -gt 0 ] && break
    done
    if [ "${#TS[@]}" -eq 0 ]; then
      echo "模拟器 180 秒内未就绪。手动启动：" >&2
      echo "  \"$EMULATOR\" -hvd \"$EMU_NAME\" -path \"$EMU_PATH\"" >&2
      exit 1
    fi
  fi
  if [ "${#TS[@]}" -gt 1 ]; then
    echo "检测到多台设备，请用 --device 指定其一：" >&2
    printf "  %s\n" "${TS[@]}" >&2
    exit 1
  fi
  HDC_TARGET="${TS[0]}"
fi

echo "目标设备：$HDC_TARGET"
HDC_ARGS=(-t "$HDC_TARGET")
hdc_() { "$HDC" "${HDC_ARGS[@]}" "$@"; }

# ---- 2. 构建 + 签名 ----
echo "[1/4] 构建并签名"
DEVECO_HOME="$DEVECO_HOME" bash tools/sign-hap.sh

# ---- 3. 安装 ----
echo "[2/4] 安装到 $HDC_TARGET"
LOG="$(mktemp)"
if ! hdc_ install -r dist/harmony03-signed.hap 2>&1 | tee "$LOG" | grep -q "successfully"; then
  if grep -q "9568332" "$LOG"; then
    echo "  签名不一致，卸载旧包后重装"
    hdc_ uninstall "$BUNDLE" >/dev/null 2>&1 || true
    hdc_ install -r dist/harmony03-signed.hap
  else
    cat "$LOG"; rm -f "$LOG"; exit 1
  fi
fi
rm -f "$LOG"

# ---- 4. 启动 ----
echo "[3/4] 启动 $BUNDLE/$ABILITY"
hdc_ shell aa start -a "$ABILITY" -b "$BUNDLE"

echo "[4/4] 完成。实时日志："
echo "  \"$HDC\" -t $HDC_TARGET shell hilog | grep carbon"