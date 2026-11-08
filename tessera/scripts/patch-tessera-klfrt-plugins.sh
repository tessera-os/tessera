#!/bin/sh
# Compatibility repair for a local KLF aarch64-unknown-tessera runtime built
# before the Foundation Plugin service surface was added. No proprietary files,
# firmware or device access is involved.
#
# The Kira runtime library is still allowed to link these five service calls,
# but Tessera does not implement a marketplace plugin host. Answer -1
# (PluginFailure.Unavailable) rather than leaving relocations unresolved or
# pretending plugin startup succeeds. This is the ARM64 C ABI, with no libc
# dependency and no C code inside Tessera's runtime.
set -eu

selected="$HOME/.klf/toolchains/klf/current.toml"
if [ ! -f "$selected" ]; then echo "Missing selected KLF toolchain: $selected" >&2; exit 1; fi
channel=$(sed -n 's/^channel = "\([^"]*\)"/\1/p' "$selected" | head -1)
version=$(sed -n 's/^version = "\([^"]*\)"/\1/p' "$selected" | head -1)
if [ -z "$channel" ] || [ -z "$version" ]; then
    echo "Cannot determine active KLF runtime from $selected" >&2
    exit 1
fi
archive=${1:-"$HOME/.klf/toolchains/klf/$channel/$version/platforms/aarch64-unknown-tessera/libklfrt.a"}
llvm=${TESSERA_LLVM:-"$HOME/.kira/toolchains/llvm/23.1.0/aarch64-macos"}
nm="$llvm/bin/llvm-nm"
clang="$llvm/bin/clang"
ar="$llvm/bin/llvm-ar"
ranlib="$llvm/bin/llvm-ranlib"

for tool in "$nm" "$clang" "$ar" "$ranlib"; do
    if [ ! -x "$tool" ]; then echo "Missing LLVM tool: $tool" >&2; exit 1; fi
done
if [ ! -f "$archive" ]; then echo "Missing Tessera target runtime: $archive" >&2; exit 1; fi

symbols='klfsvc_plugin_start klfsvc_plugin_poll klfsvc_plugin_wait klfsvc_plugin_stop klfsvc_plugin_share_file'
defined=$("$nm" --defined-only "$archive")
complete=1
for symbol in $symbols; do
    if ! printf '%s\n' "$defined" | grep -Eq " [TW] ${symbol}$"; then complete=0; fi
done
if [ "$complete" -eq 1 ]; then
    echo "Plugin service ABI already present; runtime untouched"
    exit 0
fi

for symbol in $symbols; do
    if printf '%s\n' "$defined" | grep -Eq " [TW] ${symbol}$"; then
        echo "Partial plugin ABI in runtime, refusing to add conflicting implementations" >&2
        exit 1
    fi
done

temporary=$(mktemp -d "${TMPDIR:-/tmp}/tessera-klfrt-plugin.XXXXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
cat > "$temporary/plugins.S" <<'EOF'
    .text
    .p2align 2
    .global klfsvc_plugin_start
    .global klfsvc_plugin_poll
    .global klfsvc_plugin_wait
    .global klfsvc_plugin_stop
    .global klfsvc_plugin_share_file
    .type klfsvc_plugin_start, %function
    .type klfsvc_plugin_poll, %function
    .type klfsvc_plugin_wait, %function
    .type klfsvc_plugin_stop, %function
    .type klfsvc_plugin_share_file, %function
klfsvc_plugin_start:
klfsvc_plugin_poll:
klfsvc_plugin_wait:
klfsvc_plugin_stop:
klfsvc_plugin_share_file:
    mov x0, #-1
    ret
EOF
"$clang" --target=aarch64-linux-gnu -c "$temporary/plugins.S" -o "$temporary/tessera-plugin-unavailable.o"
"$nm" --defined-only "$temporary/tessera-plugin-unavailable.o" | grep 'klfsvc_plugin_'

# Keep the original (32 MiB) archive for reproducibility and rollback.
if [ ! -f "$archive.before-plugins" ]; then cp "$archive" "$archive.before-plugins"; fi
cp "$archive" "$temporary/libklfrt.a"
"$ar" r "$temporary/libklfrt.a" "$temporary/tessera-plugin-unavailable.o"
"$ranlib" "$temporary/libklfrt.a"
"$nm" --defined-only "$temporary/libklfrt.a" | grep 'klfsvc_plugin_'
cp "$temporary/libklfrt.a" "$archive"
echo "Updated Tessera-target runtime; original: $archive.before-plugins"