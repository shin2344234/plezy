#!/bin/sh
# Writes src/Module.symvers from the exports of the running kernel and its loaded modules, so
# modpost can resolve amdgpu's imports and fill in its depends field. The kernel has no
# CONFIG_MODVERSIONS, so every CRC is 0. amdgpu's own exports are left out.
# Run as root on the host.
DV=/home/deck/dev/dv
OUT=$DV/src/Module.symvers
VER=$(uname -r)
grep ' __ksymtab_' /proc/kallsyms | awk '{print $3, ($4 == "" ? "vmlinux" : $4)}' |
  sed -e 's/^__ksymtab_//' -e 's/\[//' -e 's/\]//' | sort -u |
  while read sym mod; do
    [ "$mod" = amdgpu ] && continue
    if [ "$mod" = vmlinux ]; then
      path=vmlinux
    else
      path=$(modinfo -k $VER -F filename "$mod" 2>/dev/null | sed -e "s#^.*/modules/$VER/##" -e 's/\.ko.*$//')
      [ -n "$path" ] || path=$mod
    fi
    printf '0x00000000\t%s\t%s\tEXPORT_SYMBOL_GPL\t\n' "$sym" "$path"
  done > $OUT.tmp
mv $OUT.tmp $OUT
chown deck:deck $OUT
echo "$(wc -l < $OUT) exports, $(cut -f3 $OUT | sort -u | wc -l) objects"
