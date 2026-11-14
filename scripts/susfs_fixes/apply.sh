#!/usr/bin/env bash
# 应用 SUSFS 补丁及各内核版本所需的上下文修复
# 依赖环境变量：
#   ANDROID_VERSION KERNEL_VERSION KSU_VARIANT OS_PATCH_LEVEL SUB_LEVEL
#   KERNEL_ROOT SUSFS4KSU KERNEL_PATCHES LEGACY_SUKISU_CONFIG
# 调用前必须将工作目录设为 $KERNEL_ROOT
set -eo pipefail

# 列出当前目录下不属于上游的 .rej（相对路径，已排序）。
# 上游分支可能自带已提交的 .rej（如 android15-6.6-2026-04 的 mm/rmap.c.rej，
# 是上游解决合并冲突时的残留），那不是本补丁的冲突；但 patch 失败时会覆盖同名文件，
# 所以只有「被 git 跟踪且未改动」的才视为上游自带。
# 不在 git 仓库里（本地 verify_context.sh）时 git 命令为空，退回全部 .rej
list_upstream_rej() {
  git ls-files -- '*.rej' 2>/dev/null | while IFS= read -r f; do
    git diff --quiet -- "$f" 2>/dev/null && echo "$f"
  done
}
list_untracked_rej() {
  comm -23 \
    <(find . -type f -name '*.rej' | sed 's|^\./||' | sort) \
    <(list_upstream_rej | sort)
}

echo "应用 SUSFS 补丁..."

SUSFS_PATCH="50_add_susfs_in_gki-$ANDROID_VERSION-$KERNEL_VERSION.patch"
cp "$SUSFS4KSU/kernel_patches/$SUSFS_PATCH" ./common/
cp "$SUSFS4KSU"/kernel_patches/fs/* ./common/fs/
cp "$SUSFS4KSU"/kernel_patches/include/linux/* ./common/include/linux/

case "$KSU_VARIANT" in
  "Official")
    cd ./KernelSU
    cp "$SUSFS4KSU"/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch ./
    patch -p1 --forward < 10_enable_susfs_for_ksu.patch || true

    cd ..
    ;;
  "Next"|"SukiSU"|"SukiSU(40726)"|"SukiSU(40548)"|"BakaSU")
    echo "Next/SukiSU/SukiSU(40726)/SukiSU(40548)/BakaSU 使用内置 SUSFS 支持"
    ;;
esac

cd "$KERNEL_ROOT/common"
CURRENT_SUB="$SUB_LEVEL"
if [[ ! "$CURRENT_SUB" =~ ^[0-9]+$ ]]; then
  CURRENT_SUB=99999
fi

# 兼容缺少 VMA padding 接口的 5.10.66～209、5.15.74～144 和 6.1.25～68
if grep -qF 'VMA_PAD_START(vma)' "$SUSFS_PATCH" \
  && ! grep -Rqs 'VMA_PAD_START' ./include/linux; then
  echo "目标内核未提供 VMA_PAD_START，使用 vma->vm_end 兼容 SUSFS OPEN_REDIRECT"
  sed -i 's/VMA_PAD_START(vma)/vma->vm_end/g' "$SUSFS_PATCH"
fi

adjust_legacy_fdinfo_context() {
  sed -i '/^[[:space:]]*\/\*$/,/^[[:space:]]*u32 mask = mark->mask & IN_ALL_EVENTS;$/d' fs/notify/fdinfo.c
  perl -i -pe 's/\bmask,\s*mark->ignored_mask/inotify_mark_user_mask(mark)/g' fs/notify/fdinfo.c
  perl -i -pe 's/ignored_mask:%x/ignored_mask:0/g' fs/notify/fdinfo.c
}

restore_legacy_fdinfo_context() {
  perl -i -pe 's/^(\s+if \(inode\) \{)/$1\n\t\t\/\*\n\t\t * IN_ALL_EVENTS represents all of the mask bits\n\t\t * that we expose to userspace.  There is at\n\t\t * least one bit (FS_EVENT_ON_CHILD) which is\n\t\t * used only internally to the kernel.\n\t\t *\/\n\t\tu32 mask = mark->mask & IN_ALL_EVENTS;/m' fs/notify/fdinfo.c
  perl -i -pe 's/\binotify_mark_user_mask\(mark\)/mask, mark->ignored_mask/g' fs/notify/fdinfo.c
  perl -i -pe 's/ignored_mask:0/ignored_mask:%x/g' fs/notify/fdinfo.c
}

# 临时调整旧内核源码上下文，使 SUSFS 主补丁可以匹配
if [[ "$ANDROID_VERSION" == "android12" && "$KERNEL_VERSION" == "5.10" ]]; then
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -le 43 ]]; then
    echo "临时调整 Android 12 5.10 base.c 上下文"
    perl -i -pe 's/(int|size_t)\s+this_len\s*=\s*min_t\s*\(\s*\1\s*,/size_t this_len = min_t(size_t,/;' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 117 ]]; then
    echo "临时调整 Android 12 5.10 fdinfo.c 上下文"
    adjust_legacy_fdinfo_context
  fi
fi

if [[ "$ANDROID_VERSION" == "android13" && "$KERNEL_VERSION" == "5.15" ]]; then
  if [[ "$CURRENT_SUB" -le 41 ]]; then
    echo "临时调整 Android 13 5.15 namespace.c/open.c/fdinfo.c 上下文"
    if ! grep -qF '#include <linux/mnt_idmapping.h>' fs/namespace.c; then
      sed -i '/^#include <linux\/shmem_fs.h>$/a #include <linux/mnt_idmapping.h>' fs/namespace.c
    fi
    if ! grep -qF '#include <linux/mnt_idmapping.h>' fs/open.c; then
      sed -i '/^#include <linux\/compat.h>$/a #include <linux/mnt_idmapping.h>' fs/open.c
    fi
    adjust_legacy_fdinfo_context
  fi
  # 新版补丁需要 trace hook include 作上下文；旧版固定补丁可能不需要。
  NS_BLK_515_ADJUST=""
  if awk '/^diff --git a\/fs\/namespace.c /{f=1;next} /^diff --git /{f=0}
    f && $0 == " #include <trace/hooks/blk.h>" {found=1} END{exit !found}' "$SUSFS_PATCH"; then
    if ! grep -qxF '#include <trace/hooks/blk.h>' fs/namespace.c; then
      sed -i '/^#include "internal.h"$/a #include <trace/hooks/blk.h>' fs/namespace.c
      NS_BLK_515_ADJUST=added
    fi
  elif grep -qxF '#include <trace/hooks/blk.h>' fs/namespace.c; then
    sed -i '/^#include <trace\/hooks\/blk.h>$/d' fs/namespace.c
    NS_BLK_515_ADJUST=removed
  fi

  TASK_MM_515_ADJUST=""
  if awk '/^diff --git a\/fs\/proc\/task_mmu.c /{f=1;next} /^diff --git /{f=0}
    f && $0 == " #include <trace/hooks/mm.h>" {found=1} END{exit !found}' "$SUSFS_PATCH"; then
    if ! grep -qxF '#include <trace/hooks/mm.h>' fs/proc/task_mmu.c; then
      sed -i '/^#include <linux\/pkeys.h>$/a #include <trace/hooks/mm.h>' fs/proc/task_mmu.c
      TASK_MM_515_ADJUST=added
    fi
  elif grep -qxF '#include <trace/hooks/mm.h>' fs/proc/task_mmu.c; then
    sed -i '/^#include <trace\/hooks\/mm.h>$/d' fs/proc/task_mmu.c
    TASK_MM_515_ADJUST=removed
  fi
fi

if [[ "$ANDROID_VERSION" == "android14" && "$KERNEL_VERSION" == "6.1" ]]; then
  if [[ "$CURRENT_SUB" -le 25 ]] && ! grep -qF '#include <trace/hooks/sched.h>' fs/proc/base.c; then
    echo "临时调整 Android 14 6.1 sched.h 上下文"
    sed -i '/^#include <trace\/events\/oom.h>$/a #include <trace/hooks/sched.h>' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 141 ]] && ! grep -qF '#include <linux/dma-buf.h>' fs/proc/base.c; then
    echo "临时调整 Android 14 6.1 dma-buf.h 上下文"
    sed -i '/^#include <linux\/cpufreq_times.h>$/a #include <linux/dma-buf.h>' fs/proc/base.c
  fi
  # 6.1.157 起源码在 internal.h 后有 trace/hooks/blk.h；SUSFS 主补丁 2026-10-19 起
  # （simonpunk 8a3d6fd 基于 6.1.176 重做）把它当作上下文，旧版补丁没有。
  # 按补丁实际上下文与源码是否一致决定临时加或删，同时兼容新旧补丁和固定提交
  NS_BLK_PATCH=""
  if awk '
    /^diff --git a\/fs\/namespace.c / { in_namespace = 1; next }
    /^diff --git / { in_namespace = 0 }
    in_namespace && $0 == " #include <trace/hooks/blk.h>" { found = 1 }
    END { exit !found }
  ' "$SUSFS_PATCH"; then
    NS_BLK_PATCH=1
  fi
  NS_BLK_ADJUST=""
  if [[ -n "$NS_BLK_PATCH" ]] && ! grep -qxF '#include <trace/hooks/blk.h>' fs/namespace.c; then
    echo "临时调整 Android 14 6.1 namespace.c 上下文（补全 blk.h）"
    sed -i '/^#include "internal.h"$/a #include <trace/hooks/blk.h>' fs/namespace.c
    NS_BLK_ADJUST=added
  elif [[ -z "$NS_BLK_PATCH" ]] && grep -qxF '#include <trace/hooks/blk.h>' fs/namespace.c; then
    echo "临时调整 Android 14 6.1 namespace.c 上下文（移除 blk.h）"
    sed -i '/^#include <trace\/hooks\/blk.h>$/d' fs/namespace.c
    NS_BLK_ADJUST=removed
  fi
fi

if [[ "$ANDROID_VERSION" == "android15" && "$KERNEL_VERSION" == "6.6" ]]; then
  if [[ "$CURRENT_SUB" -le 92 ]] && ! grep -qF '#include <linux/dma-buf.h>' fs/proc/base.c; then
    echo "临时调整 Android 15 6.6 base.c 上下文"
    sed -i '/^#include <linux\/cpufreq_times.h>$/a #include <linux/dma-buf.h>' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 57 ]] && ! grep -qF '#include <linux/zswap.h>' mm/memory.c; then
    echo "临时调整 Android 15 6.6 memory.c 上下文"
    sed -i '/^#include <linux\/sched\/sysctl.h>$/a #include <linux/zswap.h>' mm/memory.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android16" && "$KERNEL_VERSION" == "6.12" ]]; then
  # 按所选补丁临时补齐或移除 include，同时兼容新版和固定旧版补丁。
  EXEC_DMA_ADJUST=""
  if awk '/^diff --git a\/fs\/exec.c /{f=1;next} /^diff --git /{f=0}
    f && $0 == " #include <linux/dma-buf.h>" {found=1} END{exit !found}' "$SUSFS_PATCH"; then
    if ! grep -qxF '#include <linux/dma-buf.h>' fs/exec.c; then
      sed -i '/^#include <linux\/ksm.h>$/a #include <linux/dma-buf.h>' fs/exec.c
      EXEC_DMA_ADJUST=added
    fi
  elif grep -qxF '#include <linux/dma-buf.h>' fs/exec.c; then
    sed -i '/^#include <linux\/dma-buf.h>$/d' fs/exec.c
    EXEC_DMA_ADJUST=removed
  fi

  # 只替换补丁的纯上下文，保留内核原有的 VMA 接口。
  if grep -qF 'if (!vma_pages(vma))' fs/proc/task_mmu.c; then
    sed -i 's/^ \tif (!vma_data_pages(vma))$/ \tif (!vma_pages(vma))/' "$SUSFS_PATCH"
  fi

  SUSFS_612_GUARD_OLD_ROLLUP=0
  if grep -qF $' \t\t\tsmap_gather_stats(priv, vma, &mss);' "$SUSFS_PATCH" \
    && awk '/^static int show_smaps_rollup\(/{f=1}
      /^static const struct seq_operations proc_pid_smaps_op/{f=0}
      f && /smap_gather_stats\(vma, &mss,/{old=1} END{exit !old}' fs/proc/task_mmu.c; then
    ROLLUP_CALLS=$(awk '/^static int show_smaps_rollup\(/{f=1}
      /^static const struct seq_operations proc_pid_smaps_op/{f=0}
      f && /^\t+smap_gather_stats\(vma, &mss, (0|last_vma_end)\);$/{n++}
      END{print n+0}' fs/proc/task_mmu.c)
    if [[ "$ROLLUP_CALLS" != 3 ]]; then
      echo "::error::旧版 rollup 统计调用已变化，停止适配"
      exit 1
    fi
    # 两个新版 rollup hunk 改由版本修复阶段补齐等价统计守卫。
    if ! awk '/^diff --git /{f=($0 ~ /^diff --git a\/fs\/proc\/task_mmu.c /);skip=0}
      /^@@ /{skip=f && /static int show_smaps_rollup/;if(skip)n++}
      !skip{print} END{exit(n!=2)}' "$SUSFS_PATCH" > "${SUSFS_PATCH}.tmp"; then
      rm -f "${SUSFS_PATCH}.tmp"
      echo "::error::新版 rollup hunk 已变化，停止适配"
      exit 1
    fi
    chmod --reference="$SUSFS_PATCH" "${SUSFS_PATCH}.tmp"
    mv "${SUSFS_PATCH}.tmp" "$SUSFS_PATCH"
    SUSFS_612_GUARD_OLD_ROLLUP=1
  fi
fi

# 新版内核在 super.c 的 internal.h 之后新增了 trace/hooks/fs.h，
# 旧版 SUSFS 主补丁以 thaw_super_locked 为上下文插入 extern 声明，会整段被拒绝；
# 上游 2026-09-15 起已把声明挪到 unnamed_dev_ida 之后，不再依赖这段上下文，
# 但 ShirkNeko fork 尚未同步（固定提交的旧版补丁不改 super.c），只对旧版补丁做临时调整
SUPER_FS_H_REMOVED=""
if grep -q '^ static int thaw_super_locked' "$SUSFS_PATCH" \
  && grep -qF '#include <trace/hooks/fs.h>' fs/super.c; then
  echo "临时调整 super.c 上下文"
  sed -i '/^#include <trace\/hooks\/fs.h>$/,+1d' fs/super.c
  SUPER_FS_H_REMOVED=1
fi

patch -p1 < "$SUSFS_PATCH" || true

# 为尚未提供 SU 会话 FD 接口的 SukiSU/BakaSU 恢复旧版 exec hook 行为
EXEC_HELPER=""
if [[ "$KSU_VARIANT" == SukiSU* || "$KSU_VARIANT" == "BakaSU" ]]; then
  if grep -qF 'ksu_install_su_fd();' fs/exec.c; then
    EXEC_HELPER="ksu_install_su_fd"
  elif grep -qF 'ksu_handle_post_execveat_sucompat(' fs/exec.c; then
    EXEC_HELPER="ksu_handle_post_execveat_sucompat"
  fi
fi
if [[ -n "$EXEC_HELPER" ]] \
  && ! grep -RqsE --include='*.c' "^[[:space:]]*int[[:space:]]+${EXEC_HELPER}[[:space:]]*\(" "$KERNEL_ROOT/KernelSU/kernel"; then
  echo "$KSU_VARIANT 尚未提供 $EXEC_HELPER，恢复旧版 exec hook"
  sed -i '/^extern int ksu_install_su_fd(void);$/d' fs/exec.c
  sed -i '/^extern int ksu_handle_post_execveat_sucompat(/,+1d' fs/exec.c
  sed -i 's/is_su_session = !\(ksu_handle_execveat[^;]*;\)/\1/' fs/exec.c
  sed -i '/^[[:space:]]*bool is_su_session = false;$/d' fs/exec.c
  sed -i '/^[[:space:]]*if (unlikely(is_su_session && retval >= 0))$/,+1d' fs/exec.c
  sed -i '/^[[:space:]]*if (unlikely(is_su_session))$/,+1d' fs/exec.c
  sed -i '/^#ifdef CONFIG_KSU_SUSFS$/N;/^#ifdef CONFIG_KSU_SUSFS\n#endif \/\/ #ifdef CONFIG_KSU_SUSFS$/d' fs/exec.c
  if grep -qE 'ksu_install_su_fd|ksu_handle_post_execveat_sucompat|is_su_session' fs/exec.c; then
    echo "::error::$KSU_VARIANT exec hook 结构已变化，无法完成兼容修复"
    exit 1
  fi
fi

# 上游 5.10 补丁把 susfs_sus_kstat_spoof_vfs_statfs 的 extern 声明放在了
# susfs_statfs_by_dentry 之后，clang -Werror 会报隐式声明；声明晚于使用时前移
if [[ -f fs/statfs.c ]] && grep -qF 'susfs_sus_kstat_spoof_vfs_statfs(' fs/statfs.c; then
  STATFS_USE=$(grep -n 'if (!susfs_sus_kstat_spoof_vfs_statfs(' fs/statfs.c | head -1 | cut -d: -f1)
  STATFS_DECL=$(grep -n '^extern int susfs_sus_kstat_spoof_vfs_statfs(' fs/statfs.c | head -1 | cut -d: -f1)
  if [[ -n "$STATFS_USE" && -n "$STATFS_DECL" && "$STATFS_DECL" -gt "$STATFS_USE" ]] \
    && grep -q '^static int susfs_statfs_by_dentry(' fs/statfs.c; then
    echo "前移 statfs.c 中 susfs_sus_kstat_spoof_vfs_statfs 的声明"
    sed -i '/^static int susfs_statfs_by_dentry(/i extern int susfs_sus_kstat_spoof_vfs_statfs(struct inode *inode, struct kstatfs *buf, bool *is_fuse);' fs/statfs.c
  fi
fi

# 上游 2026-11-01 起 priority_uid_filter 的两个凭据辅助函数定义在 #ifdef 之外，
# 调用点却全在 CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER 内；SukiSU/BakaSU 的 Kconfig 尚无该选项，
# 函数成为死代码，开启 CONFIG_WERROR 的内核（android12-5.10-2023-01 起）报 unused function
if grep -qE '^static (struct cred \*|void )susfs_(switch_to_ksu_domain|restore_creds)\(' fs/susfs.c; then
  echo "为 priority_uid_filter 凭据辅助函数标记 __maybe_unused"
  sed -i -E 's/^static (struct cred \*|void )(susfs_switch_to_ksu_domain|susfs_restore_creds)\(/static __maybe_unused \1\2(/' fs/susfs.c
fi

# 上游 2026-11-02 起 priority_uid_filter 的声明与定义都受 CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER 保护，
# 该选项由 10_enable_susfs_for_ksu.patch 加进 KSU 的 Kconfig；SukiSU builtin 不打该补丁，
# Kconfig 尚未同步，却无条件调用这些接口，编译时报隐式声明。按上游定义补上选项
KSU_KCONFIG="$KERNEL_ROOT/KernelSU/kernel/Kconfig"
if [[ -f "$KSU_KCONFIG" ]] \
  && grep -qF 'CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER' include/linux/susfs.h \
  && ! grep -qE '^config KSU_SUSFS_PRIORITY_UID_FILTER$' "$KSU_KCONFIG" \
  && grep -RqsE --include='*.c' 'susfs_(parse_priority_app_strings|set_priority_uid_filter)\(' "$KERNEL_ROOT/KernelSU/kernel"; then
  echo "$KSU_VARIANT 的 Kconfig 缺少 KSU_SUSFS_PRIORITY_UID_FILTER，按上游定义补上"
  cat >> "$KSU_KCONFIG" << 'EOF'

config KSU_SUSFS_PRIORITY_UID_FILTER
	bool "Enable to allow adding user-defined uids that will be hidden from getpriority/setpriority/ioprio_get/ioprio_set syscall"
	depends on KSU_SUSFS
	default y
	help
	  - Allow hiding user-defined uids from syscalls like getpriority/setpriority/ioprio_get/ioprio_set.
	  - Effective on all processes with uid >= 10000.
EOF
fi

# 在编译前报告 SUSFS 主补丁产生的冲突文件，上游自带的 .rej 不计入
mapfile -t SUSFS_REJ_FILES < <(list_untracked_rej)
SUSFS_REJ_COUNT=${#SUSFS_REJ_FILES[@]}
if [ "$SUSFS_REJ_COUNT" -gt 0 ]; then
  echo "::warning title=SUSFS 补丁冲突::SUSFS 主补丁产生了 ${SUSFS_REJ_COUNT} 个 .rej 冲突文件，可能导致后续编译失败（详见 Rejects 产物）"
  printf '%s\n' "${SUSFS_REJ_FILES[@]}"
fi

# 还原仅用于补丁匹配的临时源码调整
if [[ "$ANDROID_VERSION" == "android12" && "$KERNEL_VERSION" == "5.10" ]]; then
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -le 43 ]]; then
    echo "还原 Android 12 5.10 base.c 临时调整"
    sed -i 's/^size_t this_len = min_t(size_t, count, PAGE_SIZE);$/int this_len = min_t(int, count, PAGE_SIZE);/' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 117 ]]; then
    echo "还原 Android 12 5.10 fdinfo.c 临时调整"
    restore_legacy_fdinfo_context
  fi
fi

if [[ "$ANDROID_VERSION" == "android13" && "$KERNEL_VERSION" == "5.15" ]]; then
  if [[ "$CURRENT_SUB" -le 41 ]]; then
    echo "还原 Android 13 5.15 临时调整"
    sed -i '/#include <linux\/mnt_idmapping.h>$/d' fs/namespace.c
    sed -i '/#include <linux\/mnt_idmapping.h>$/d' fs/open.c
    restore_legacy_fdinfo_context
    sed -i 's|i_uid_into_mnt(i_user_ns(&fi->inode), &fi->inode).val|i_uid_into_mnt(\&init_user_ns, \&fi->inode).val|g' fs/susfs.c
    sed -i 's|i_uid_into_mnt(i_user_ns(inode), inode).val|i_uid_into_mnt(\&init_user_ns, inode).val|g' fs/susfs.c
  fi
  if [[ "$NS_BLK_515_ADJUST" == "added" ]]; then
    sed -i '/^#include <trace\/hooks\/blk.h>$/d' fs/namespace.c
  elif [[ "$NS_BLK_515_ADJUST" == "removed" ]] && ! grep -qxF '#include <trace/hooks/blk.h>' fs/namespace.c; then
    sed -i '/^#include "internal.h"$/a #include <trace/hooks/blk.h>' fs/namespace.c
  fi
  if [[ "$TASK_MM_515_ADJUST" == "added" ]]; then
    sed -i '/^#include <trace\/hooks\/mm.h>$/d' fs/proc/task_mmu.c
  elif [[ "$TASK_MM_515_ADJUST" == "removed" ]] && ! grep -qxF '#include <trace/hooks/mm.h>' fs/proc/task_mmu.c; then
    sed -i '/^#include <linux\/pkeys.h>$/a #include <trace/hooks/mm.h>' fs/proc/task_mmu.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android14" && "$KERNEL_VERSION" == "6.1" ]]; then
  if [[ "$CURRENT_SUB" -le 25 ]]; then
    sed -i '/^#include <trace\/hooks\/sched.h>$/d' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 141 ]]; then
    echo "还原 Android 14 6.1 base.c 临时调整"
    sed -i '/^#include <linux\/dma-buf.h>$/d' fs/proc/base.c
  fi
  if [[ "$NS_BLK_ADJUST" == "added" ]]; then
    echo "还原 Android 14 6.1 namespace.c 临时调整（移除补全的 blk.h）"
    sed -i '/^#include <trace\/hooks\/blk.h>$/d' fs/namespace.c
  elif [[ "$NS_BLK_ADJUST" == "removed" ]] && ! grep -qxF '#include <trace/hooks/blk.h>' fs/namespace.c; then
    echo "还原 Android 14 6.1 namespace.c 临时调整（恢复 blk.h）"
    sed -i '/^#include "internal.h"$/a #include <trace/hooks/blk.h>' fs/namespace.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android15" && "$KERNEL_VERSION" == "6.6" ]]; then
  if [[ "$CURRENT_SUB" -le 92 ]]; then
    echo "还原 Android 15 6.6 base.c 临时调整"
    sed -i '/^#include <linux\/dma-buf.h>$/d' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 57 ]]; then
    echo "还原 Android 15 6.6 memory.c 临时调整"
    sed -i '/^#include <linux\/zswap.h>$/d' mm/memory.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android16" && "$KERNEL_VERSION" == "6.12" ]]; then
  if [[ "$EXEC_DMA_ADJUST" == "added" ]]; then
    sed -i '/^#include <linux\/dma-buf.h>$/d' fs/exec.c
  elif [[ "$EXEC_DMA_ADJUST" == "removed" ]] && ! grep -qxF '#include <linux/dma-buf.h>' fs/exec.c; then
    sed -i '/^#include <linux\/ksm.h>$/a #include <linux/dma-buf.h>' fs/exec.c
  fi
fi

if [[ -n "$SUPER_FS_H_REMOVED" ]] \
  && ! grep -qF '#include <trace/hooks/fs.h>' fs/super.c; then
  echo "还原 super.c 临时调整"
  sed -i '/^#include "internal.h"$/a #include <trace/hooks/fs.h>' fs/super.c
fi

fix_missing_vm_flags_clear() {
  if [[ "$OS_PATCH_LEVEL" == "2024-11" ]] && grep -qF 'vm_flags_clear(new_vma, VM_PAD_MASK);' ./mm/mmap.c; then
    sed -i 's/vm_flags_clear(new_vma, VM_PAD_MASK);/new_vma->vm_flags \&= ~VM_PAD_MASK;/' ./mm/mmap.c
  fi
}

fix_task_mmu_show_pad() {
  local max_sub="$1"
  local excluded_patch_level="${2:-}"

  # 仅固定旧版 SUSFS 补丁会引入 goto show_pad，最新版已不再包含该代码
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -le "$max_sub" ]] \
    && { [[ -z "$excluded_patch_level" ]] || [[ "$OS_PATCH_LEVEL" != "$excluded_patch_level" ]]; }; then
    sed -i -e 's/goto show_pad;/return 0;/' ./fs/proc/task_mmu.c
  fi
}

# Android 12 - 5.10 修复
if [[ "$ANDROID_VERSION" == "android12" && "$KERNEL_VERSION" == "5.10" ]]; then
  # 修复 2024-11 分支: mmap.c 调用了 vm_flags_clear()，但同分支 mm.h 未提供 helper
  fix_missing_vm_flags_clear
  fix_task_mmu_show_pad 209
fi

# Android 13 - 5.15 修复
  if [[ "$ANDROID_VERSION" == "android13" && "$KERNEL_VERSION" == "5.15" ]]; then
  # 修复 2024-11 分支: mmap.c 调用了 vm_flags_clear()，但同分支 mm.h 未提供 helper
  fix_missing_vm_flags_clear
  fix_task_mmu_show_pad 148 "2024-05"
fi

# Android 14 - 6.1 修复
if [[ "$ANDROID_VERSION" == "android14" && "$KERNEL_VERSION" == "6.1" ]]; then
  fix_task_mmu_show_pad 75 "2024-05"
fi

# Android 15 - 6.6 修复
if [[ "$ANDROID_VERSION" == "android15" && "$KERNEL_VERSION" == "6.6" ]]; then
  # 修复老版 SukiSU 6.6.50~6.6.58: task_mmu.c 打入 SUSFS 后使用 vma，但旧源码没有对应声明
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -ge 50 && "$CURRENT_SUB" -le 58 ]] \
    && grep -qF 'vma = find_vma(mm, start_vaddr);' ./fs/proc/task_mmu.c; then
    TASK_MMU_PATCH="$KERNEL_PATCHES/wild/archived/susfs_fix_patches/v2.1.0/a15-6.6/task_mmu.c.patch"
    if [ ! -f "$TASK_MMU_PATCH" ]; then
      echo "::error::补丁不存在: $TASK_MMU_PATCH"
      exit 1
    fi
    cp "$TASK_MMU_PATCH" ./
    if patch -p1 --dry-run < task_mmu.c.patch >/dev/null 2>&1; then
      patch -p1 --no-backup-if-mismatch < task_mmu.c.patch
      echo "已应用 Android 15 6.6.50~6.6.58 task_mmu.c 归档修复补丁"
    else
      echo "Android 15 6.6.50~6.6.58 task_mmu.c 归档修复补丁已应用或当前上下文不匹配，跳过"
    fi
  fi
fi

# Android 16 - 6.12 修复
if [[ "$ANDROID_VERSION" == "android16" && "$KERNEL_VERSION" == "6.12" ]]; then
  # 仅过滤隐藏映射的统计调用，不改原有迭代、锁操作和范围更新。
  if [[ "$SUSFS_612_GUARD_OLD_ROLLUP" == "1" ]]; then
    ROLLUP_MARKERS=$(grep -cF '/* SUSFS 6.12 旧版 rollup 统计兼容守卫。 */' fs/proc/task_mmu.c || true)
    if [[ "$ROLLUP_MARKERS" == 0 ]]; then
      if ! awk '/^static int show_smaps_rollup\(/{f=1}
        /^static const struct seq_operations proc_pid_smaps_op/{f=0}
        f && /^\t+smap_gather_stats\(vma, &mss, (0|last_vma_end)\);$/ {
          match($0,/^\t+/);indent=substr($0,1,RLENGTH)
          print indent "/* SUSFS 6.12 旧版 rollup 统计兼容守卫。 */"
          print "#ifdef CONFIG_KSU_SUSFS_SUS_MAP"
          print indent "if (!vma->vm_file || !(SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file))))"
          print "#endif"
          print "\t" $0;n++;next
        }
        {print} END{exit(n!=3)}' fs/proc/task_mmu.c > fs/proc/task_mmu.c.tmp; then
        rm -f fs/proc/task_mmu.c.tmp
        echo "::error::无法补齐旧版 rollup 统计守卫"
        exit 1
      fi
      chmod --reference=fs/proc/task_mmu.c fs/proc/task_mmu.c.tmp
      mv fs/proc/task_mmu.c.tmp fs/proc/task_mmu.c
    elif [[ "$ROLLUP_MARKERS" != 3 ]]; then
      echo "::error::旧版 rollup 统计守卫不完整"
      exit 1
    fi
  fi

  # 固定旧版 SukiSU 在 6.12 上会重复定义 setresuid hook
  SETUID_HOOK="$KERNEL_ROOT/common/drivers/kernelsu/setuid_hook.c"
  if [[ -n "$LEGACY_SUKISU_CONFIG" && -f "$SETUID_HOOK" ]] \
    && grep -qF 'defined(CONFIG_KSU_MANUAL_HOOK))' "$SETUID_HOOK"; then
    sed -i 's/defined(CONFIG_KSU_MANUAL_HOOK))/!defined(CONFIG_KSU_SUSFS) \&\& defined(CONFIG_KSU_MANUAL_HOOK))/' "$SETUID_HOOK"
    echo "已修复 setuid_hook.c 重复定义问题"
  fi
fi

# ===========================================================================
# selinux_hide 路由修复（BakaSU + SUSFS）
# SUSFS 在 selinuxfs 里挂的垫片用 live 策略计算 access/context 的结果，
# KernelSU 注入的类型与规则因此仍然对 app 可见，隐藏开关等于没生效。
# 这里只把垫片里「uid >= 10000 且 hide 运行中」那一支的被调用者，换成
# KernelSU 自己的 my_write_access / my_write_context（基于 backup_sepolicy）。
# ===========================================================================
if [[ "${KSU_VARIANT}" == "BakaSU" ]]; then
  SELINUXFS="$KERNEL_ROOT/common/security/selinux/selinuxfs.c"
  if [[ -f "$SELINUXFS" ]]; then
    echo "==== selinux_hide: 构建时实际使用的 SUSFS 垫片 ===="
    sed -n '/handle_sel_write_access/,/^}/p' "$SELINUXFS"
    sed -n '/handle_sel_write_context/,/^}/p' "$SELINUXFS"
    echo "==== selinux_hide: 垫片结束 ===="

    python3 - "$SELINUXFS" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

if 'return my_write_access(' in s:
    print('selinux_hide: 路由补丁已存在，跳过')
    sys.exit(0)

decl = ('#ifdef CONFIG_KSU_SUSFS\n'
        'extern ssize_t my_write_access(struct file *, char *, size_t);\n'
        'extern ssize_t my_write_context(struct file *, char *, size_t);\n'
        '#endif\n')
if 'my_write_access(struct file' not in s:
    anchor = 'extern void initialize_fake_status(void);\n'
    if anchor not in s:
        sys.exit('selinux_hide: 锚点缺失（initialize_fake_status 声明），放弃')
    s = s.replace(anchor, anchor + decl, 1)

for kind in ('access', 'context'):
    pat = re.compile(
        r'(static ssize_t handle_sel_write_%s\(struct file \*file, char \*buf, size_t size\)'
        r'\s*\{.*?return\s+)susfs_sel_write_%s\(file, buf, size\)' % (kind, kind), re.S)
    s, n = pat.subn(lambda m: m.group(1) + 'my_write_%s(file, buf, size)' % kind, s, count=1)
    if n != 1:
        sys.exit('selinux_hide: 锚点缺失（handle_sel_write_%s），放弃' % kind)

# 调用点换掉后，两个 static 垫片就没人用了，内核 -Werror 会直接报 unused-function
s, n = re.subn(r'static ssize_t (susfs_sel_write_(?:access|context))\(',
               r'static ssize_t __attribute__((unused)) \1(', s)
if n != 2:
    sys.exit('selinux_hide: 未能给 susfs_sel_write_* 标记 unused（匹配 %d 处），放弃' % n)

open(p, 'w', encoding='utf-8').write(s)
print('selinux_hide: 已把 access/context 垫片改接 my_write_*')
PY

    echo "==== selinux_hide: 修改后的结果 ===="
    grep -n -A3 'handle_sel_write_access(struct file' "$SELINUXFS" | head -12
    grep -n -A3 'handle_sel_write_context(struct file' "$SELINUXFS" | head -12
  fi
fi

# ===========================================================================
# selinux_hide 三通道一致性（BakaSU + SUSFS）· 第二部分
# 上面那段把 selinuxfs.c 的 access/context 垫片改接回 my_write_*（backup 策略），
# 这里补上 /proc/<pid>/attr/current：SUSFS 的 handle_selinux_setprocattr 原本
# 调 susfs_selinux_setprocattr，用 live 策略解析上下文；对 u:r:ksu:s0 这类被
# 注入的类型会走到 -EACCES（CONTEXT_RECOGNIZED），与另外两路的 -EINVAL 口径
# 分裂，检测器一交叉就穿。改接 my_setprocattr 之后三路统一由 backup_sepolicy
# 回答。同时在 KernelSU 侧给 my_setprocattr / my_write_* 补 backup_sepolicy 判空。
# ===========================================================================
if [[ "$KSU_VARIANT" == "BakaSU" ]]; then
  HOOKS="$KERNEL_ROOT/common/security/selinux/hooks.c"
  SELINUXFS="$KERNEL_ROOT/common/security/selinux/selinuxfs.c"
  KSU_HIDE="$KERNEL_ROOT/KernelSU/kernel/feature/selinux_hide.c"
  KSU_MK="$KERNEL_ROOT/KernelSU/kernel/tools/susfs_compat.mk"

  selinux_hide_fail() {
    echo "::error::selinux_hide 三通道一致性检查失败: $*"
    exit 1
  }

  # ---------- 1. 把 setprocattr 垫片改接回 my_setprocattr ----------
  if [[ -f "$HOOKS" ]] && grep -qF 'susfs_selinux_setprocattr(name, value, size)' "$HOOKS"; then
    python3 - "$HOOKS" <<'PY'
import re, sys

p = sys.argv[1]
s = open(p, encoding='utf-8').read()

if 'return my_setprocattr(' in s:
    print('selinux_hide: setprocattr 路由补丁已存在，跳过')
    sys.exit(0)

anchor = 'static int handle_selinux_setprocattr(const char *name, void *value, size_t size)\n'
decl = ('#ifdef CONFIG_KSU_SUSFS\n'
        'extern int my_setprocattr(const char *name, void *value, size_t size);\n'
        '#endif\n')
if 'extern int my_setprocattr(' not in s:
    if anchor not in s:
        sys.exit('selinux_hide: 锚点缺失（handle_selinux_setprocattr），放弃')
    s = s.replace(anchor, decl + anchor, 1)

call = 'return susfs_selinux_setprocattr(name, value, size);'
if s.count(call) != 1:
    sys.exit('selinux_hide: setprocattr 调用点数量异常(%d)，放弃' % s.count(call))
s = s.replace(call, 'return my_setprocattr(name, value, size);', 1)

# 原垫片不再被调用，-Werror 会报 unused-function
s, n = re.subn(r'static int (susfs_selinux_setprocattr)\(',
               r'static int __attribute__((unused)) \1(', s)
if n != 1:
    sys.exit('selinux_hide: 未能标记 susfs_selinux_setprocattr 为 unused（匹配 %d 处）' % n)

open(p, 'w', encoding='utf-8').write(s)
print('selinux_hide: setprocattr 已改接 my_setprocattr（backup 策略）')
PY

    echo "==== selinux_hide: hooks.c 改接结果 ===="
    sed -n '/static int handle_selinux_setprocattr/,/^}/p' "$HOOKS"
    echo "==== selinux_hide: hooks.c 结束 ===="
  fi

  # ---------- 2. backup_sepolicy 判空（KernelSU 侧） ----------
  # backup_sepolicy 在 hide 尚未 enable 时是 NULL；三个入口一旦被调用，
  # security_context_to_sid_with_policy() 会直接解引用。判空后回 -EINVAL，
  # 与「该上下文不存在」的语义一致，也不会在开机早期崩内核。
  if [[ -f "$KSU_HIDE" ]]; then
    python3 - "$KSU_HIDE" <<'PY'
import re, sys

p = sys.argv[1]
s = open(p, encoding='utf-8').read()

if 'if (unlikely(!backup_sepolicy))' in s:
    print('selinux_hide: backup_sepolicy 判空已存在，跳过')
    sys.exit(0)

anchors = [
    'my_write_context(struct file *file',
    'my_write_access(struct file *file',
]
if 'ksu_handle_selinux_setprocattr(const char *name' in s:
    anchors.append('ksu_handle_selinux_setprocattr(const char *name')
elif 'my_setprocattr(const char *name' in s:
    anchors.append('my_setprocattr(const char *name')
else:
    sys.exit('selinux_hide: 未找到 setprocattr 函数定义，放弃')

call = 'security_context_to_sid_with_policy(backup_sepolicy,'
inserted = 0
for anchor in anchors:
    start = s.find(anchor)
    if start < 0:
        sys.exit('selinux_hide: 未找到函数 %s，放弃' % anchor)
    idx = s.find(call, start)
    if idx < 0:
        sys.exit('selinux_hide: %s 内未找到 backup_sepolicy 解析点，放弃' % anchor)
    # 定位「语句」起点：调用可能写成  length =\n        security_context_to_sid_with_policy(...)
    line_start = s.rfind('\n', 0, idx) + 1
    prev_end = line_start - 1
    if prev_end > 0:
        prev_start = s.rfind('\n', 0, prev_end) + 1
        prev_line = s[prev_start:prev_end].strip()
        cur_prefix = s[line_start:idx].strip()
        if prev_line.endswith('=') and cur_prefix == '':
            line_start = prev_start
    indent = re.match(r'[ \t]*', s[line_start:]).group(0)
    guard = (indent + 'if (unlikely(!backup_sepolicy))\n' +
             indent + '    return -EINVAL;\n')
    s = s[:line_start] + guard + s[line_start:]
    inserted += 1

open(p, 'w', encoding='utf-8').write(s)
print('selinux_hide: 已为 %d 个入口补 backup_sepolicy 判空' % inserted)
PY
  fi

  # ---------- 3. 源码级硬断言：任何一项不符即中断，避免产出「口径分裂」内核 ----------
  grep -q  'KSU_COMPAT_HAS_SUSFS_FEATURE_SELINUX_HIDE' "$KSU_MK" \
    || selinux_hide_fail "susfs_compat.mk 缺少 SELINUX_HIDE 兼容宏（SUSFS 未接管 selinux_hide）"

  grep -qE 'ssize_t[[:space:]]+([[:alnum:]_]+[[:space:]]+)*my_write_access[[:space:]]*\(' "$KSU_HIDE" \
    || selinux_hide_fail "my_write_access 不是可被外部引用的全局符号"
  grep -qE 'ssize_t[[:space:]]+([[:alnum:]_]+[[:space:]]+)*my_write_context[[:space:]]*\(' "$KSU_HIDE" \
    || selinux_hide_fail "my_write_context 不是可被外部引用的全局符号"

  if grep -qE '^int[[:space:]]+my_setprocattr[[:space:]]*\(' "$KSU_HIDE"; then
    :
  elif grep -qE 'int[[:space:]]+__nocfi[[:space:]]+ksu_handle_selinux_setprocattr[[:space:]]*\(' "$KSU_HIDE"; then
    # BakaSU main 的形态：定义名经 KSU_COMPAT_..._SELINUX_HIDE 宏改写成 my_setprocattr
    :
  else
    selinux_hide_fail "selinux_hide.c 未找到可用的 setprocattr 实现"
  fi

  grep -q  'if (unlikely(!backup_sepolicy))' "$KSU_HIDE" \
    || selinux_hide_fail "backup_sepolicy 判空未注入"

  grep -q  'ksu_selinux_hide_running' "$HOOKS" \
    || selinux_hide_fail "hooks.c 中缺少 ksu_selinux_hide_running（SUSFS selinux_hide 未生效）"
  grep -q  'return my_setprocattr(' "$HOOKS" \
    || selinux_hide_fail "hooks.c 未把 setprocattr 改接为 my_setprocattr"
  grep -qE 'static int[[:space:]]+__attribute__\(\(unused\)\)[[:space:]]+susfs_selinux_setprocattr[[:space:]]*\(' "$HOOKS" \
    || echo "::warning::selinux_hide: hooks.c 中的 susfs_selinux_setprocattr 未标记 unused"

  grep -q  'return my_write_access(' "$SELINUXFS" \
    || selinux_hide_fail "selinuxfs.c 未把 access 改接为 my_write_access"
  grep -q  'return my_write_context(' "$SELINUXFS" \
    || selinux_hide_fail "selinuxfs.c 未把 context 改接为 my_write_context"

  # CONFIG_KSU=m 时 __maybe_static 会展开成 static，hooks.c 的外部引用会链接失败。
  # 注意：本脚本跑在「配置内核选项」之前，此刻 defconfig 里可能还没有 CONFIG_KSU 行，
  # 只有显式写了 =m 才视为致命。
  if [[ -n "${DEFCONFIG:-}" ]] && [[ -f "$DEFCONFIG" ]]; then
    if grep -qx 'CONFIG_KSU=m' "$DEFCONFIG"; then
      selinux_hide_fail "CONFIG_KSU=m，__maybe_static 展开为 static，my_setprocattr 无法被 hooks.c 引用"
    fi
    echo "selinux_hide: defconfig 当前 CONFIG_KSU 状态: $(grep -E '^CONFIG_KSU=' "$DEFCONFIG" || echo '尚未写入（稍后由配置步骤追加）')"
  fi

  echo "==== selinux_hide 三通道一致性源码检查通过 ===="
fi
