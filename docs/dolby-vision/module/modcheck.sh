#!/bin/sh
# Checks the built amdgpu.ko against the stock one and the running kernel.
# Run as root on the host (needs /proc/kallsyms with addresses hidden or not: names suffice).
DV=/home/deck/dev/dv
KO=$DV/src/drivers/gpu/drm/amd/amdgpu/amdgpu.ko
VER=$(uname -r)
STOCK=$DV/stock.ko
[ -f $STOCK ] || zstd -qdc /usr/lib/modules/$VER/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko.zst > $STOCK
echo "running:       $VER"
echo "built vermagic: $(modinfo -F vermagic $KO)"
echo "stock vermagic: $(modinfo -F vermagic $STOCK)"
echo "built depends:  $(modinfo -F depends $KO)"
echo "stock depends:  $(modinfo -F depends $STOCK)"
modinfo -p $KO | grep -i "dvbridge\|hdmi_3d"
printf "property names in the module: "; grep -c -a "DVBRIDGE_DV_STANDARD_LAB" $KO
# Imports: every undefined symbol must be exported by the kernel or by a loaded module.
nm -u $KO | awk '{print $2}' | sort -u > $DV/built.undef
nm -u $STOCK | awk '{print $2}' | sort -u > $DV/stock.undef
comm -23 $DV/built.undef $DV/stock.undef > $DV/new.undef
echo "new imports: $(wc -l < $DV/new.undef)"
awk '{print $3}' /proc/kallsyms | sed 's/^__ksymtab_//' | sort -u > $DV/kallsyms.names
grep '__ksymtab_' /proc/kallsyms | awk '{print $3}' | sed 's/^__ksymtab_//' | sort -u > $DV/exported
while read s; do
  if grep -qx "$s" $DV/exported; then echo "  ok        $s"; else echo "  MISSING   $s"; fi
done < $DV/new.undef
echo "stock imports not exported now: $(comm -23 $DV/stock.undef $DV/exported | wc -l)"
