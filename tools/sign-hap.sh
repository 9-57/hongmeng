#!/usr/bin/env bash
# 构建 + 本地签名：产出可直接 hdc install 的 HAP
# 依赖：DevEco Studio 自带 SDK / JDK（hap-sign-tool.jar）
# 用法：bash tools/sign-hap.sh [debug|release]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# DevEco 安装位置按候选顺序探测（本机是 "D:/DevEco studio"）
resolve_deveco() {
  for c in "${DEVECO_HOME:-}" "D:/DevEco studio" "D:/deveco-studio/DevEco Studio" \
           "D:/HarmonyOS/DevEco Studio6.0.1/DevEco Studio" "C:/Program Files/Huawei/DevEco Studio"; do
    if [ -n "$c" ] && [ -d "$c/sdk" ]; then printf '%s' "$c"; return 0; fi
  done
  echo "找不到 DevEco Studio 安装目录，请设置 DEVECO_HOME（例如 D:/DevEco studio）" >&2
  return 1
}

DEVECO_HOME="$(resolve_deveco)"
SDK_LIB="$DEVECO_HOME/sdk/default/openharmony/toolchains/lib"
BUILD_MODE="${1:-debug}"

export DEVECO_SDK_HOME="$DEVECO_HOME/sdk"
export PATH="$DEVECO_HOME/tools/node:$PATH"

cd "$ROOT"
node "$DEVECO_HOME/tools/hvigor/bin/hvigorw.js" \
  --mode module -p product=default -p buildMode="$BUILD_MODE" assembleHap --no-daemon

UNSIGNED="entry/build/default/outputs/default/entry-default-unsigned.hap"
mkdir -p dist
java -jar "$SDK_LIB/hap-sign-tool.jar" sign-app \
  -keyAlias "openharmony application release" \
  -signAlg SHA256withECDSA \
  -mode localSign \
  -appCertFile signature/harmony03_chain.cer \
  -profileFile signature/openharmony.p7b \
  -inFile "$UNSIGNED" \
  -outFile dist/harmony03-signed.hap \
  -keystoreFile signature/openharmony.p12 \
  -keyPwd 123456 -keystorePwd 123456

echo "signed hap -> dist/harmony03-signed.hap"
