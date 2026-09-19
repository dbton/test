# MIPS 大端 / 软浮点 交叉编译工具链 (GitHub Actions 构建)

- 宿主机: x86_64 Arch Linux (在 `archlinux:base-devel` 容器中构建, 产物依赖 Arch 的 glibc)
- 目标机: MIPS, 大端, o32 ABI, 软浮点, musl libc
- 默认 ISA: mips32r2 (常见路由器/嵌入式设备: MT7620、AR71xx、AR9331 等)
- 构建工具: crosstool-NG 1.29.0 (GCC 16.2, binutils 2.47, musl 1.2.6)

选择 musl 并以 `-Os` 编译目标侧库, 是为了适配低内存、低存储的设备。

## 使用方法

1. 把本目录推送到 GitHub 仓库的 `main` 分支, Actions 会自动构建。
2. 在 Actions 页面下载 artifact, 或推送 `v*` 标签自动发布 Release。
3. 手动触发 (workflow_dispatch) 时可用 `mips_arch` 输入覆盖 ISA, 例如 `mips32` 或 `mips1`。

```sh
git init && git add . && git commit -m "mips toolchain ci"
git remote add origin git@github.com:<you>/<repo>.git
git push -u origin main
```

## 在 Arch Linux 上安装并使用

```sh
sudo tar -C /opt -xJf mips-linux-musl-gcc-toolchain-x86_64-archlinux.tar.xz
export PATH=/opt/mips-linux-musl/bin:$PATH
mips-linux-musl-gcc -Os -static -s -ffunction-sections -fdata-sections -Wl,--gc-sections -o app app.c
```

实际三元组以 CI 日志中 `Target tuple:` 一行为准。

针对低存储设备的建议:

- `-static` 加 musl: 单个程序不依赖目标机上的共享库, 部署最简单。
- `-Os -s -ffunction-sections -fdata-sections -Wl,--gc-sections`: 最小体积。
- 多个程序时改为动态链接, 只需把工具链 `<tuple>/sysroot/lib/libc.so` 拷到目标机 (约 600KB), libstdc++ 按需拷贝。

## 调整配置

编辑 `defconfig` 后推送即可。常用项:

| 需求 | 修改 |
|------|------|
| 更老的 CPU | `CT_ARCH_ARCH="mips32"` 或 `"mips1"` |
| 指定 CPU 调优 | 增加 `CT_ARCH_TUNE="24kc"` |
| 目标机内核很旧 | 增加 `CT_LINUX_V_4_19=y` 等 (`ct-ng menuconfig` 查看可选版本) |
| 不需要 C++ | 删除 `CT_CC_LANG_CXX=y` |
| 需要 gdbserver | 增加 `CT_DEBUG_GDB=y` `CT_GDB_CROSS=y` `CT_GDB_GDBSERVER=y` |

本地调试配置: 安装 crosstool-NG 后在本目录运行 `ct-ng defconfig && ct-ng menuconfig && ct-ng savedefconfig`。

## 故障排查

- **`Installing GMP for host` 阶段 `configure: error: could not find a working compiler`**: Arch 的 gcc 已是 16.x, 默认 C23 (`-std=gnu23`)。GMP 6.3.0 的 configure 测试程序里有 `void g(){}` 然后带 6 个参数调用它, 在 C23 下 `()` 等于 `(void)`, 编译报 `too many arguments to function 'g'`, GMP 就判定编译器不可用。crosstool-NG 1.27.0 没有修复, 1.29.0 自带补丁, 工作流已升级。若必须用旧版 ct-ng, 可在 defconfig 加 `CT_EXTRA_CFLAGS_FOR_HOST="-std=gnu17"`。
- **`musl: download failed`**: crosstool-NG 1.27.0 内置的 musl 地址 `http://www.musl-libc.org` 从 CI 网络经常超时。工作流的 "Prefetch sources" 步骤会先从 musl.libc.org / buildroot / openwrt 镜像下载并校验 SHA256, 放入 `tarballs/` 供 ct-ng 直接使用。其他包下载失败时, 可以在该步骤里按同样方式再加一行 `fetch`。
- **定位报错**: 构建失败时, "Show build error context" 步骤会把 `build.log` 里所有 `[ERROR]` 行, 以及第一处 `[ERROR]` 之前 300 行的上下文 (真正的编译/配置错误通常在这里) 打印到 Actions 日志, 并上传完整 `build.log` 作为 artifact。
- **日志噪音**: `defconfig` 已关闭 ct-ng 的进度转轮 (`CT_LOG_PROGRESS_BAR`)。CI 不是交互终端, 转轮的每次刷新都会变成一行 `[mm:ss] /`, 会产生几万行无用输出。控制台只输出 EXTRA 级别, 完整 DEBUG 日志仍在 `build.log`。
