#!/bin/bash
set -euo pipefail

# 构建只依赖系统自带的框架。默认输出到临时目录，有 --install 时才写入应用程序目录。
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--install" ) ]]; then
    printf '用法：%s [--install]\n' "$0" >&2
    exit 2
fi

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_name="GamePrep"
app_id="io.github.lq-0519.GamePrep"
install_path="/Applications/$app_name.app"
working_dir="$(mktemp -d "${TMPDIR:-/tmp}/GamePrep.XXXXXX")"
bundle="$working_dir/$app_name.app"
install_stage=""
install_lock=""
keep_build=false
swap_started=false
install_complete=false

# 在发生安装错误或收到中断信号时恢复旧包。恢复失败时保留旧包所在目录，供手动恢复。
cleanup() {
    local status=$?
    trap - EXIT
    set +e

    if [[ -n "$install_stage" && "$install_complete" == false ]]; then
        if [[ "$swap_started" == true && ! -e "$install_stage/$app_name.app" && -d "$install_path" && ! -L "$install_path" ]]; then
            mv "$install_path" "$install_stage/Unverified.app"
        fi
        if [[ -d "$install_stage/Previous.app" ]]; then
            if [[ -e "$install_path" || -L "$install_path" ]] || ! mv "$install_stage/Previous.app" "$install_path"; then
                printf '原版本保留在 %s/Previous.app\n' "$install_stage" >&2
                install_stage=""
            fi
        fi
    fi

    if [[ -n "$install_stage" ]]; then
        rm -rf "$install_stage"
    fi
    if [[ -n "$install_lock" ]]; then
        rmdir "$install_lock"
    fi
    if [[ "$keep_build" == false ]]; then
        rm -rf "$working_dir"
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$bundle/Contents/MacOS"
cp "$project_dir/Resources/Info.plist" "$bundle/Contents/Info.plist"
/usr/bin/plutil -lint "$bundle/Contents/Info.plist"

# 直接用本机工具链生成可执行文件，模块缓存和应用包均放在仓库外。
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
xcrun --sdk macosx swiftc \
    -sdk "$sdk_path" \
    -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$working_dir/module-cache" \
    -O -o "$bundle/Contents/MacOS/$app_name" \
    "$project_dir"/Sources/*.swift

/usr/bin/codesign --force --sign - --timestamp=none "$bundle"
/usr/bin/codesign --verify --strict "$bundle"

if [[ "$#" -eq 0 ]]; then
    rm -rf "$working_dir/module-cache"
    keep_build=true
    printf '已构建：%s\n' "$bundle"
    exit 0
fi

# 在目标目录所在文件系统暂存和验证应用，让最后一次移动无需跨卷复制。
install_stage="$(mktemp -d "/Applications/.GamePrep.install.XXXXXX")"
/usr/bin/ditto "$bundle" "$install_stage/$app_name.app"
/usr/bin/codesign --verify --strict "$install_stage/$app_name.app"

# 串行替换应用包，并用应用标识确认目标位置上的已有应用属于本项目。
if ! mkdir "/Applications/.GamePrep.install.lock" 2>/dev/null; then
    printf '另一个安装正在使用 GamePrep 的安装位置。\n' >&2
    exit 1
fi
install_lock="/Applications/.GamePrep.install.lock"

if [[ -e "$install_path" || -L "$install_path" ]]; then
    existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$install_path/Contents/Info.plist" 2>/dev/null || true)"
    if [[ -L "$install_path" || "$existing_id" != "$app_id" ]]; then
        printf '安装位置已有其他文件：%s\n' "$install_path" >&2
        exit 1
    fi
    mv "$install_path" "$install_stage/Previous.app"
fi

swap_started=true
mv "$install_stage/$app_name.app" "$install_path"
/usr/bin/codesign --verify --strict "$install_path"
install_complete=true
printf '已安装：%s\n' "$install_path"
