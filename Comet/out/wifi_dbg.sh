#!/bin/bash
OUT=~/wifi_dbg_$(date +%H%M%S)
mkdir -p "$OUT"
adb wait-for-device
sleep 20

adb shell svc wifi disable; sleep 2
adb shell svc wifi enable;  sleep 12

adb shell dmesg > "$OUT/dmesg_full.txt"
adb logcat -b all -d > "$OUT/logcat_full.txt"
adb shell ls -l /vendor/etc/wifi/ > "$OUT/wifi_files.txt"

# 只取最後一次 wifi_on 之後的 kernel log,並濾掉雜訊
awk '/wl_android_wifi_on in/{n=NR} {a[NR]=$0} END{if(n)for(i=n;i<=NR;i++)print a[i]; else print "NO wl_android_wifi_on FOUND"}' \
  "$OUT/dmesg_full.txt" \
 | grep -vE "libprocessgroup|cgroup|flags_health|IRadioData|cbd:|lhd|gpsd|omx|max77833|sec-battery|cisd|binder|init:|CPU[0-9]|IRQ|vfsspi|kworker|audit|swapper|iod:|migration|thread_hotplug" \
 > "$OUT/key.txt"

echo "===== $OUT/key.txt ====="
cat "$OUT/key.txt" | head -120
