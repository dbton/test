# 交叉编译工具链 (GitHub Actions 构建)

在 x86_64 Arch Linux 容器内用 crosstool-NG 构建面向嵌入式 Linux 设备的交叉工具链。
每个目标一个目录, 矩阵并行构建, 推送标签自动发布 Release。

- 宿主机: x86_64 Arch Linux (`archlinux:base-devel` 容器, 产物链接到 Arch 的 glibc)
- 构建工具: crosstool-NG 1.29.0 (GCC 16.2, binutils 2.47, musl 1.2.6)
- 所有目标共用 `common/defconfig` 的策略: musl libc, 目标侧库 `-Os`, C 和 C++, 全部 strip, 三元组不带 vendor。
  这些选择是为了适配低内存、低存储的设备。

## 内置目标

| 目录 (`targets/`) | 三元组 | 架构 | 典型设备 |
|---|---|---|---|
| `mips-linux-musl` | mips-linux-musl | MIPS32r2, 大端, o32, 软浮点 | MT7620 / AR71xx / AR9331 |
| `mipsel-linux-musl` | mipsel-linux-musl | MIPS32r2, 小端, o32, 软浮点 | MT7621 / MT7628 / MT7688 |
| `arm-linux-musleabi` | arm-linux-musleabi | ARMv5TE, 软浮点, EABI | Kirkwood / Orion NAS, ARM926 SoC |
| `arm-linux-musleabihf` | arm-linux-musleabihf | ARMv7-A, VFPv3-D16 硬浮点, Thumb-2 | IPQ40xx / i.MX6 / 全志 H3 / 树莓派 2 |
| `aarch64-linux-musl` | aarch64-linux-musl | ARMv8-A 64 位 | MT7622 / IPQ807x / RK33xx / 树莓派 3+ |
| `riscv64-linux-musl` | riscv64-linux-musl | RV64GC, lp64d | 全志 D1 / CV1800B / JH7110 |

## 使用方法

- **推送到 `main`**: 构建全部目标, 每个目标一个 artifact。
- **手动触发** (Actions 页面 Run workflow):
  - `targets`: 逗号分隔的目录名, 例如 `mips-linux-musl,aarch64-linux-musl`; 或 `all`。
  - `extra_config`: 追加到 defconfig 末尾的配置行, 覆盖同名项。例如 `CT_ARCH_ARCH="mips32"` 给老 MIPS 设备换 ISA。
- **发布 Release**: 推送 `v*` 标签。全部目标构建成功后, 自动创建 Release, 附带每个目标的 tar.xz、合并的 `SHA256SUMS` 和自动生成的说明 (三元组、架构参数、组件版本、安装命令)。

  ```sh
  git tag -a v2.0.0 -m "v2.0.0" && git push origin v2.0.0
  ```

  若个别目标失败, 在 Actions 页面 "Re-run failed jobs", 成功后 Release 任务会接着运行。

## 安装与使用

```sh
sudo tar -C /opt -xJf aarch64-linux-musl-toolchain-x86_64-archlinux-v2.0.0.tar.xz
export PATH=/opt/aarch64-linux-musl/bin:$PATH
aarch64-linux-musl-gcc -Os -static -s -ffunction-sections -fdata-sections -Wl,--gc-sections -o app app.c
```

安装路径是 `/opt/x-tools/<三元组>` 解包后的 `/opt/<三元组>`。

针对低存储设备的建议:

- `-static` 加 musl: 程序不依赖目标机上的共享库, 部署最简单; 静态 hello world 约 20KB。
- `-Os -s -ffunction-sections -fdata-sections -Wl,--gc-sections`: 最小体积。
- 多个程序时改为动态链接, 只需把 `<三元组>/sysroot/lib/libc.so` 拷到目标机 (约 600KB), libstdc++ 按需拷贝。

## 添加新目标

1. 新建 `targets/<name>/defconfig`, 只写架构相关的行 (参考现有目标)。目录名建议与三元组一致且唯一, 它会出现在产物文件名里。
2. 本地校验 (需要安装 crosstool-NG 1.29.0):

   ```sh
   scripts/configure.sh <name>        # 打印三元组、关键设置、组件版本
   ct-ng menuconfig && ct-ng savedefconfig   # 可选: 交互调整后, 把架构相关行抄回 targets/<name>/defconfig
   ```

3. 推送, 或手动触发时在 `targets` 里只填这个目标。

冒烟测试 (`scripts/smoke-test.sh`) 是通用的: 按 `.config` 核对 ELF 位宽、端序、机器类型, 以及 MIPS / 32 位 ARM / RISC-V / PowerPC 的浮点 ABI, 再在 qemu-user 下运行。
支持 qemu 的架构: mips 系列、arm、aarch64、riscv、powerpc、x86、s390x、m68k、sh4、sparc、or1k、xtensa、microblaze、loongarch64、alpha、hppa; 其他架构跳过运行测试但仍做 ELF 检查。

## 目录结构

```
common/defconfig          所有目标共用的策略
targets/<name>/defconfig  每个目标的架构相关配置
scripts/list-targets.sh   目标列表 -> 矩阵 JSON
scripts/configure.sh      拼接 defconfig 并运行 ct-ng defconfig
scripts/prefetch.sh       从镜像预取 musl 源码包
scripts/smoke-test.sh     通用冒烟测试
scripts/package.sh        打包 + sha256 + 发布说明片段
scripts/release-notes.sh  合并发布说明
scripts/error-context.sh  失败时打印定位信息
```

## 常用调整

| 需求 | 修改 |
|------|------|
| 更老的 MIPS CPU | 目标 defconfig 里 `CT_ARCH_ARCH="mips32"` 或 `"mips1"`, 或手动触发时用 `extra_config` |
| 指定 CPU 调优 | 增加 `CT_ARCH_TUNE="24kc"` |
| 目标机内核很旧 | 增加 `CT_LINUX_V_4_19=y` 等 (`ct-ng menuconfig` 查看可选版本) |
| 改用 glibc | 目标 defconfig 里加 `CT_LIBC_GLIBC=y` (覆盖 common 的 musl; 会有 override 警告, 属预期) |
| 不需要 C++ | common 或目标 defconfig 里删除 / 覆盖 `CT_CC_LANG_CXX` |
| 需要 gdbserver | 增加 `CT_DEBUG_GDB=y` `CT_GDB_CROSS=y` `CT_GDB_GDBSERVER=y` |

## 故障排查

- **定位报错**: 构建失败时, "Show build error context" 步骤会打印 `build.log` 里所有 `[ERROR]` 行、第一处 `[ERROR]` 之前 300 行的上下文, 以及最近一次 configure 的 `config.log` 错误行; 完整日志作为 `build-log-<target>` artifact 上传。
- **`Installing GMP for host` 阶段 `configure: error: could not find a working compiler`**: Arch 的 gcc 已是 16.x, 默认 C23。GMP 6.3.0 的 configure 测试程序里 `void g(){}` 被带 6 个参数调用, 在 C23 下报 `too many arguments`。crosstool-NG 1.29.0 自带补丁; 若必须用旧版 ct-ng, 在 common/defconfig 加 `CT_EXTRA_CFLAGS_FOR_HOST="-std=gnu17"`。
- **`musl: download failed`**: 官方站点从 CI 网络经常超时。`scripts/prefetch.sh` 会先从 musl.libc.org / buildroot / openwrt 镜像下载并校验 SHA256。其他包下载失败时, 在该脚本里按同样方式再加一行 `fetch`。
- **日志噪音**: `common/defconfig` 已关闭 ct-ng 的进度转轮; 控制台只输出 EXTRA 级别, 完整 DEBUG 日志在 `build.log`。
