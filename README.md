# 交叉编译工具链 (GitHub Actions 构建)

用 crosstool-NG 构建面向嵌入式 Linux 设备的交叉工具链。
每个目标一个目录, 按 host × target 矩阵并行构建, 推送标签自动发布 Release。

- **host** 是运行交叉编译器的机器; **target** 是运行编译结果的设备。两者独立选择。
- 构建工具: crosstool-NG 1.29.0 (GCC 16.2, binutils 2.47, musl 1.2.6)
- 所有目标共用 `common/defconfig` 的策略: musl libc, 目标侧库 `-Os`, C 和 C++, 全部 strip, 三元组不带 vendor。
  这些选择是为了适配低内存、低存储的设备。

## 内置 host

| 名称 (`hosts.json`) | 原生构建 runner | 构建容器 | 编译器运行环境 |
|---|---|---|---|
| `x86_64-archlinux` | `ubuntu-24.04` | `archlinux:base-devel` | x86_64 Arch Linux, 滚动更新的 glibc |
| `aarch64-ubuntu22.04` | `ubuntu-24.04-arm` | `ubuntu:22.04` | aarch64 Linux, Ubuntu 22.04 / glibc 2.35 基线 |

工具链在对应 CPU 的 runner 上原生构建, build 与 host 相同, 不使用 Canadian cross。
aarch64 使用 Ubuntu 容器, x86_64 沿用现有 Arch 容器。
默认 host 编译器动态链接到构建容器的系统库; target 使用 musl 不代表编译器本身是静态程序。
跨发行版使用时还需满足 libstdc++ 等运行库要求, 不能只根据 CPU 或 glibc 版本判断兼容性。
每份发布说明记录构建 host 和实际 glibc 版本。当前仅提供 Linux host, 不包含 macOS / Windows。

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

- **推送到 `main`**: 构建全部 host × target, 当前共 2 × 6 = 12 个任务, 每个组合一个 artifact。
- **手动触发** (Actions 页面 Run workflow):
  - `hosts`: 逗号分隔的 host 名称, 例如 `x86_64-archlinux,aarch64-ubuntu22.04`; 或 `all`。
  - `targets`: 逗号分隔的目录名, 例如 `mips-linux-musl,aarch64-linux-musl`; 或 `all`。
  - `extra_config`: 追加到 defconfig 末尾的配置行, 覆盖同名项。例如 `CT_ARCH_ARCH="mips32"` 给老 MIPS 设备换 ISA。
  - 两个选择器的空值都视为 `all`; 重复名称去重, 未知名称会在创建构建矩阵前报错。
- **发布 Release**: 推送 `v*` 标签。全部组合构建成功后, 自动创建 Release, 附带每个组合的 tar.xz、合并的 `SHA256SUMS` 和自动生成的说明 (host、三元组、架构参数、组件版本、安装命令)。

  ```sh
  git tag -a v2.0.0 -m "v2.0.0" && git push origin v2.0.0
  ```

  若个别组合失败, 在 Actions 页面 "Re-run failed jobs", 成功后 Release 任务会接着运行。

## 安装与使用

```sh
# 在 x86_64 Arch Linux 上运行编译器, 为 aarch64 Linux 设备编译程序
sudo tar -C /opt -xJf aarch64-linux-musl-toolchain-x86_64-archlinux-v2.0.0.tar.xz
export PATH=/opt/aarch64-linux-musl/bin:$PATH
aarch64-linux-musl-gcc -Os -static -s -ffunction-sections -fdata-sections -Wl,--gc-sections -o app app.c
```

安装路径是 `/opt/x-tools/<三元组>` 解包后的 `/opt/<三元组>`。
文件名格式为 `<target>-toolchain-<host>[-<tag>].tar.xz`; 现有 Arch 文件名格式保持兼容。
如果运行编译器的机器是 aarch64, 应下载 `...-toolchain-aarch64-ubuntu22.04-...tar.xz`。
不同 host 的压缩包含有相同的 target 目录, 安装时只选与当前机器匹配的一份。

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
CI 设置 `REQUIRE_EXECUTION=1`, 如果没有可用的 qemu 或同 CPU 的原生静态执行环境则失败。
`--dynamic` 模式通过 qemu 的 `-L` 参数使用目标 sysroot, 不使用 host 的动态加载器。

## 添加新 host

1. 在 `hosts.json` 添加名称与配置, 包括 `runner`、`container`、`package_manager` (`apt` / `pacman`)、`arch`、`os_id`、`version_id` 和 `label`。`os_id` / `version_id` 对应容器 `/etc/os-release`; 滚动发行版可将 `version_id` 留空。
2. 确保 runner CPU 与容器、`arch` 一致, 镜像包含 Bash, 并提供 ct-ng 构建依赖及 qemu-user。新的包管理器还需扩展 workflow 的依赖安装步骤。
3. 查看矩阵并在对应环境中校验:

   ```sh
   python3 scripts/hosts.py list all
   python3 scripts/hosts.py check <host>
   HOST_NAME=<host> scripts/configure.sh <target>
   ct-ng build."$(nproc)"
   REQUIRE_EXECUTION=1 scripts/smoke-test.sh <tuple>
   scripts/package.sh <target> <tuple> <host>
   ```

`configure.sh` 保留原有参数; CI 通过 `HOST_NAME` 环境变量检查 host, 并要求 `CT_CROSS=y`。
`package.sh` 的可选第三个参数优先于 `HOST_NAME`; 两者都省略时按当前环境匹配注册表。
CPU、发行版或版本不匹配会在打包前失败, 防止错误标记产物。构建、冒烟测试和打包应在同一 host 环境中执行。
本地配置验证仍可在其他已安装 ct-ng 的 Linux 发行版上运行; 若要发布该 host 的产物, 先增加对应配置。

脚本回归测试使用 Python 3.10+ 标准库, 不编译完整工具链:

```sh
python3 -m unittest discover -s tests -v
```

`Check scripts` 工作流会在 push / pull request 时运行这些测试及 Bash 语法检查。

## 目录结构

```
common/defconfig          所有目标共用的策略
targets/<name>/defconfig  每个目标的架构相关配置
hosts.json               host 的 runner、容器与运行环境信息
scripts/hosts.py          host 列表 -> 矩阵 JSON / 实际环境校验
scripts/list-targets.sh   目标列表 -> 矩阵 JSON
scripts/configure.sh      拼接 defconfig 并运行 ct-ng defconfig
scripts/prefetch.sh       从镜像预取 musl 源码包
scripts/smoke-test.sh     通用冒烟测试
scripts/package.sh        打包 + sha256 + 发布说明片段
scripts/release-notes.sh  合并发布说明
scripts/error-context.sh  失败时打印定位信息
tests/                   host、打包合并与冒烟执行回归测试
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

- **定位报错**: 构建失败时, "Show build error context" 步骤会打印 `build.log` 里所有 `[ERROR]` 行、第一处 `[ERROR]` 之前 300 行的上下文, 以及最近一次 configure 的 `config.log` 错误行; 完整日志作为 `build-log-<target>-<host>` artifact 上传。
- **host 不匹配**: 检查所选 runner 的 CPU 和容器的 `/etc/os-release`, 修改 `HOST_NAME` 不能改变编译器架构。ARM64 host 需要可用的 `ubuntu-24.04-arm` runner; 没有该 runner 的仓库可手动只选 x86_64 host, 或在注册表中配置对应的自托管 ARM64 runner 标签。
- **`Installing GMP for host` 阶段 `configure: error: could not find a working compiler`**: Arch 的 gcc 已是 16.x, 默认 C23。GMP 6.3.0 的 configure 测试程序里 `void g(){}` 被带 6 个参数调用, 在 C23 下报 `too many arguments`。crosstool-NG 1.29.0 自带补丁; 若必须用旧版 ct-ng, 在 common/defconfig 加 `CT_EXTRA_CFLAGS_FOR_HOST="-std=gnu17"`。
- **`musl: download failed`**: 官方站点从 CI 网络经常超时。`scripts/prefetch.sh` 会先从 musl.libc.org / buildroot / openwrt 镜像下载并校验 SHA256。其他包下载失败时, 在该脚本里按同样方式再加一行 `fetch`。
- **日志噪音**: `common/defconfig` 已关闭 ct-ng 的进度转轮; 控制台只输出 EXTRA 级别, 完整 DEBUG 日志在 `build.log`。
