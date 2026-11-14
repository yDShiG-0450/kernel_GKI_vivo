# fgetpriority: 让 getpriority/setpriority/ioprio_* 在跨 app uid 查询时返回 ESRCH
# 上游: https://github.com/aerath-stuff/fgetpriority (GPL-2.0)
ccflags-y += -Wno-error -Wno-declaration-after-statement -Wno-unused-function
obj-y += fgetpriority.o
fgetpriority-y := main.o
