# 本地签名材料

本目录用于**离线本地签名**，不依赖华为开发者账号。

| 文件 | 用途 |
| --- | --- |
| `openharmony.p12` | 密钥库（来自 OpenHarmony SDK，口令 `123456`，别名 `openharmony application release`） |
| `harmony03_chain.cer` | 应用证书链：Application Release → Application CA → Root CA（3 段） |
| `openharmony.p7b` | 已签名的 provisioning profile（release 类型，bundle-name = `com.example.harmony03`，有效期 10 年） |
| `openharmony_profile.json` | 上面 p7b 的明文来源；改 bundle-name / 有效期后重新签 |

## 构建 + 签名

```bash
bash tools/sign-hap.sh            # 产物 dist/harmony03-signed.hap
```

只重签 profile（改了包名或有效期时）：

```bash
cd signature
java -jar "$DEVECO_SDK_HOME/default/openharmony/toolchains/lib/hap-sign-tool.jar" sign-profile \
  -keyAlias "openharmony application profile release" -signAlg SHA256withECDSA -mode localSign \
  -profileCertFile "$DEVECO_SDK_HOME/default/openharmony/toolchains/lib/OpenHarmonyProfileRelease.pem" \
  -inFile openharmony_profile.json -keystoreFile openharmony.p12 -outFile openharmony.p7b \
  -keyPwd 123456 -keystorePwd 123456
```

已用 `hap-sign-tool verify-app` 校验：`Digest verify result: true` / `Verify success`。

## 限制（重要）

1. 该证书链由 **OpenHarmony 根 CA** 签发，只有信任该 CA 的设备/镜像才接受安装（OpenHarmony 开发板、
   部分开发版镜像）。**零售版 HarmonyOS NEXT 真机不接受**。
2. 真机安装需要在 DevEco Studio 登录华为账号 →
   *Project Structure → Signing Configs → Automatically generate signature*，材料落在 `~/.ohos/config`。
   hvigor 要求 `build-profile.json5` 里的密码字段是 DevEco 加密后的 32+ 位十六进制串（明文会报
   `00303116`），所以本仓库**不把 signingConfigs 写进 build-profile.json5**，而是用 `tools/sign-hap.sh`
   在构建之后手工签名。拿到自动签名材料后，二选一即可：
   - 继续用 `tools/sign-hap.sh`，把 `-appCertFile / -profileFile / -keystoreFile` 换成华为材料；
   - 或者在 DevEco 的 Project Structure 里点一次自动签名，让它替你写 `signingConfigs`。
3. 安装后通知需要用户授权（代码里已调用 `notificationManager.requestEnableNotification`）；
   实况窗走 `SlotType.SERVICE_INFORMATION` + `NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW`，
   系统是否展示还取决于设备的实况窗开关。定时提醒依赖 `CarbonWorkScheduler`（workScheduler 扩展能力），
   受系统调度策略约束，离线/省电模式下可能延后。
