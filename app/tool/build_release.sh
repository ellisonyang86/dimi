#!/usr/bin/env bash
# DIMI release 构建：注入正式环境地址（--dart-define），产出 release APK。
# 必填环境变量（未设置会直接报错退出）：
#   API_BASE_URL  正式 API 地址，如 https://api.dimi.example.com/v1
#   H5_BASE_URL   召集令 H5 落地页，如 https://h5.dimi.example.com/h5/
# 可选：
#   ICP_NUMBER    App/ICP 备案号，非空时展示在「关于 DIMI」页
# 用法（Git Bash / Linux / macOS）：
#   API_BASE_URL=https://api.dimi.example.com/v1 \
#   H5_BASE_URL=https://h5.dimi.example.com/h5/ \
#   ICP_NUMBER=京ICP备00000000号-1A \
#   bash tool/build_release.sh
set -euo pipefail

cd "$(dirname "$0")/.."

: "${API_BASE_URL:?必须设置 API_BASE_URL（正式环境 API 地址，如 https://api.dimi.example.com/v1）}"
: "${H5_BASE_URL:?必须设置 H5_BASE_URL（召集令 H5 落地页地址）}"

args=(
  build apk --release
  --dart-define=API_BASE_URL="${API_BASE_URL}"
  --dart-define=H5_BASE_URL="${H5_BASE_URL}"
)
if [[ -n "${ICP_NUMBER:-}" ]]; then
  args+=(--dart-define=ICP_NUMBER="${ICP_NUMBER}")
fi

flutter "${args[@]}"

echo "构建完成：app/build/app/outputs/flutter-apk/app-release.apk"
