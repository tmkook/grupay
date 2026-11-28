#!/usr/bin/env bash
# GruPay 日常运维脚本：构建、发布、测试与安装。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SERVER="$ROOT/server"
CLIENT="$ROOT/client"
PUBSPEC="$CLIENT/pubspec.yaml"
CONFIG="$SERVER/src/config.ts"
APK="$CLIENT/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
RELEASES="$SERVER/public/releases"

usage() {
  cat <<'EOF'
用法: ./ops.sh <命令> [参数]

命令:
  check                 客户端静态分析与测试 + 服务端类型检查与集成测试
  bump <版本>           修改 pubspec 版本，未带 +构建号时自动递增
  build [--no-test]     构建 ARM64 发布 APK（默认先跑测试），产物留在本地
  release <版本> [选项] 改版本、跑测试、构建、同步版本配置、部署并校验
       --skip-tests      跳过测试
       --install         发布后安装到手机
  deploy                仅部署当前服务端与已存在的发布包
  install [设备号]      安装当前构建的 APK，未指定时取第一台在线设备
EOF
}

die() { echo "错误: $*" >&2; exit 1; }

current_version() {
  sed -n 's/^version: *//p' "$PUBSPEC" | head -1
}

sdk_dir() {
  sed -n 's/^sdk\.dir=//p' "$CLIENT/android/local.properties" 2>/dev/null | head -1
}

aapt_path() {
  local sdk
  sdk="$(sdk_dir)"
  [ -n "$sdk" ] && [ -d "$sdk/build-tools" ] || return 1
  find "$sdk/build-tools" -maxdepth 1 -mindepth 1 -type d | sort -V | tail -1 | sed 's|$|/aapt|'
}

# 写入 pubspec 版本；未提供 +构建号时自动在当前构建号上加一。
bump_version() {
  local wanted="$1" current base build
  current="$(current_version)"
  [ -n "$wanted" ] || die "请提供版本号，例如 ./ops.sh bump 0.2.7"
  if [[ "$wanted" == *+* ]]; then
    base="${wanted%%+*}"
    build="${wanted##*+}"
  else
    base="$wanted"
    build="$((${current##*+} + 1))"
  fi
  [[ "$base" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "版本号格式应为 x.y.z 或 x.y.z+build"
  [[ "$build" =~ ^[0-9]+$ ]] || die "构建号必须是整数"
  perl -pi -e "s/^version: .*/version: $base+$build/" "$PUBSPEC"
  echo "版本: $(current_version)"
}

run_checks() {
  echo "== 客户端 =="
  (cd "$CLIENT" && flutter analyze && flutter test)
  echo "== 服务端 =="
  (cd "$SERVER" && npm run typecheck && npm test)
}

build_apk() {
  echo "== 构建 ARM64 发布包 =="
  (cd "$CLIENT" && flutter build apk --release --split-per-abi --target-platform android-arm64)
  [ -f "$APK" ] || die "未找到构建产物: $APK"
}

# 读取 APK 实际版本信息，输出 "versionCode versionName"。
apk_version() {
  local aapt
  aapt="$(aapt_path)" || die "未找到 Android build-tools 的 aapt，请检查 local.properties"
  "$aapt" dump badging "$APK" | sed -n "s/^package:.*versionCode='\([0-9]*\)'.*versionName='\([^']*\)'.*/\1 \2/p"
}

stage_apk() {
  local code ver target sha
  read -r code ver <<<"$(apk_version)"
  [ -n "$code" ] && [ -n "$ver" ] || die "无法读取 APK 版本信息"
  mkdir -p "$RELEASES"
  target="$RELEASES/grupay-$ver+$code.apk"
  cp "$APK" "$target"
  sha="$(shasum -a 256 "$target" | awk '{print $1}')"
  VER="$ver" CODE="$code" SHA="$sha" perl -0pi -e '
    s/"releaseVersion": "[^"]*"/"releaseVersion": "$ENV{VER}"/;
    s/"releaseBuild": \d+/"releaseBuild": $ENV{CODE}/;
    s/"releaseSha256": "[^"]*"/"releaseSha256": "$ENV{SHA}"/;
  ' "$CONFIG"
  echo "发布包: server/public/releases/grupay-$ver+$code.apk"
  echo "校验值: $sha"
}

deploy() {
  echo "== 部署到 Cloudflare =="
  (cd "$SERVER" && npm run typecheck && npm run deploy)
}

verify_online() {
  local domain latest
  domain="$(sed -n 's/.*"pattern": *"\([^"]*\)".*/\1/p' "$SERVER/wrangler.jsonc" | head -1)"
  [ -n "$domain" ] || die "无法从 wrangler.jsonc 读取域名"
  echo "== 校验线上版本 =="
  curl -fsS "https://$domain/api/health" && echo
  latest="$(curl -fsS "https://$domain/releases/latest.json")"
  echo "$latest"
  grep -q '"version":"'"$(current_version | cut -d+ -f1)"'"' <<<"$latest" ||
    die "线上版本与 pubspec 不一致"
}

install_apk() {
  local serial="${1:-}"
  [ -f "$APK" ] || die "本地没有构建产物，请先执行 ./ops.sh build"
  if [ -z "$serial" ]; then
    serial="$(adb devices | awk '$2 == "device" { print $1; exit }')"
  fi
  [ -n "$serial" ] || die "没有在线的 ADB 设备"
  echo "== 安装到 $serial =="
  adb -s "$serial" install -r "$APK"
  adb -s "$serial" shell dumpsys package com.grupay.cc |
    grep -E "versionName|versionCode" | head -2
}

cmd="${1:-help}"
shift || true
case "$cmd" in
  help|-h|--help) usage ;;
  check) run_checks ;;
  bump) bump_version "${1:-}" ;;
  build)
    skip_tests=false
    [ "${1:-}" = "--no-test" ] && skip_tests=true
    $skip_tests || run_checks
    build_apk
    ;;
  release)
    version="${1:-}"
    [ -n "$version" ] || die "请提供版本号，例如 ./ops.sh release 0.2.7"
    shift
    skip_tests=false; do_install=false
    for arg in "$@"; do
      case "$arg" in
        --skip-tests) skip_tests=true ;;
        --install) do_install=true ;;
        *) die "未知参数: $arg" ;;
      esac
    done
    bump_version "$version"
    $skip_tests || run_checks
    build_apk
    stage_apk
    deploy
    verify_online
    $do_install && install_apk
    ;;
  deploy) deploy && verify_online ;;
  install) install_apk "${1:-}" ;;
  *) usage && die "未知命令: $cmd" ;;
esac
