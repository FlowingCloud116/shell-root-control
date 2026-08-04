#!/system/bin/sh

# 这个安装脚本只设置模块文件权限，不在安装阶段改动 Magisk 授权策略。
# 常驻服务会在重启后关闭 Shell Root，并持续确保配对式无线调试处于开启状态。

SKIPUNZIP=0

ui_print "- Shell Root Control"

# Magisk 安装器会解压文件，但显式设置权限可以避免 ZIP 工具改写可执行位。
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/rootctld.sh" 0 0 0755
set_perm "$MODPATH/wirelessd.sh" 0 0 0755
set_perm "$MODPATH/system/bin/rootctl" 0 0 0755

ui_print "- 安装完成后重启；Shell Root 默认关闭，无线调试自动开启"
