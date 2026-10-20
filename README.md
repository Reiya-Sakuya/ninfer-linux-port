# ninfer-linux-port

**NInfer / KVMem 引擎（`ninfer-fusion-kvmem`）的 Linux x86_64 社区移植。**

> ⚠️ **非官方，社区维护，不保证维护、不保证稳定。** 见 [免责声明](#免责声明)。
> 上游仓库：[`1314521gjy/ninfer-fusion-kvmem`](https://github.com/1314521gjy/ninfer-fusion-kvmem)
> 上游对应 issue：[#15](https://github.com/1314521gjy/ninfer-fusion-kvmem/issues/15)

---

## 这是什么 / 不是什么

**是**：让上游源码树能在 Linux 上编译通过并运行的一组补丁 + 一键编译脚本。

**不是**：上游的 Linux 分支、不是 fork、不提供功能开发、不做模型转换。

**现状**：在 RTX 3080 20G（sm_86）+ CUDA 13.3 + GCC 13.3 上**编译通过、启动成功**，
KVMem 环 / host KV pinning / context cache 全部就位。

**没有验证的**：长上下文压测、并发压测、MTP 投机解码、vision、生成质量与 Windows 的逐 token 对拍。
详见 [实测边界](#实测边界)。

---

## 快速开始

### 方式 A：不想自己编（下二进制）

去 [Releases](../../releases) 下载，**先看架构对不对**：

| 文件 | 适用 GPU | 状态 |
|---|---|---|
| `ninfer-serve-linux-x86_64-sm86-cuda13.3.tar.gz` | **仅 sm_86**：RTX 30 系（3060/3070/3080/3090）、A10、A6000 等 | 实测可启动 |

**40 系（sm_89）、50 系（sm_120）不能用这个二进制**，请走方式 B 自己编。

```bash
tar xzf ninfer-serve-linux-x86_64-sm86-cuda13.3.tar.gz
chmod +x ninfer-serve
./ninfer-serve --help
```

运行期还需要（Ubuntu 24.04 包名）：

```bash
sudo apt install libavformat60 libavcodec60 libavutil58 libswscale7 libcurl4
```

驱动要求见 [docs/gotchas.md](docs/gotchas.md)。

### 方式 B：自己编（一条命令）

```bash
git clone https://github.com/Reiya-Sakuya/ninfer-linux-port.git
cd ninfer-linux-port
git clone https://github.com/1314521gjy/ninfer-fusion-kvmem.git ../ninfer-src
./build.sh ../ninfer-src/src-tree/fusion-engine-src
```

`build.sh` 会自动：拉 CUDA 13.3 镜像 → 装 gcc-13 工具链 → 应用补丁 → 编译 → 把 `ninfer-serve` 拷出来。

**大约 1.5~2 小时**（`small_t_i8` 那一段单线程很慢，正常现象）。
编译目录在容器 tmpfs 里，不会把你的盘写满，**也不会像在 btrfs 上那样把整机卡死**。

---

## 目录

```
patches/                    8 个 unified diff
apply.sh                    只应用补丁，不编译
build.sh                    一条命令：容器 + 补丁 + 编译 + 收产物
docker/                     Dockerfile.build / Dockerfile.run
docs/
  build.md                  手动编译步骤（不想用 build.sh 的话）
  gotchas.md                踩过的 6 个坑（CUDA 版本、驱动、链接顺序…）
  port-notes.md             每个补丁在做什么、为什么这么修
recipes/
  3080-20g-8g-kv.md         3080 20G + 8G KV 配方的实测参数与读数
```

---

## 补丁清单

在 `src-tree/fusion-engine-src/` 目录下 `patch -p1` 应用，或用 `./apply.sh <path>`。

| # | 文件 | 类别 | 性质 |
|---|---|---|---|
| 1 | `runtime_plan.cpp` | `size_t` / `uint64_t` 推导失败（LP64 vs LLP64） | **上游 bug，与平台无关** |
| 2 | `apps/CMakeLists.txt` | 静态库循环依赖，GNU ld 单遍扫描不过 | **上游 bug，与平台无关** |
| 3 | `gdn.cpp` | 缺 `<algorithm>` | 编译器差异 |
| 4 | `moe_kernels.cu` | `alignas` 用在 `extern __shared__` | 编译器差异 |
| 5 | `cpu_expert_nvfp4.h` | 166 处 SIMD intrinsics 的 `#pragma GCC target` | 编译器差异 |
| 6 | `expert_staging.cpp` | `GetProcessIoCounters` → `/proc/self/io` | Win32 → POSIX |
| 7 | `load/materialized.cpp` | `PrefetchVirtualMemory` / `CreateFileW` / `VirtualQuery` | Win32 → POSIX |
| 8 | `apps/cli/main.cpp` | EcoQoS 限速豁免（Windows 独有概念） | Windows 独有 |

**改动的 8 个文件全在 `qwen3_8_flash_next`（Qwen4 架构预览后端）和 CLI 里。
核心引擎、KVMem 环、`qwen3_5` 后端（Qwen3.8-27B 走的这条线）一行未动。**

1 和 2 是上游真 bug，已单独提给作者（[issue #15](https://github.com/1314521gjy/ninfer-fusion-kvmem/issues/15) 评论区）。
其余 6 个是 Linux 支持补齐。

---

## 实测边界

**验证过的**（RTX 3080 20G / 驱动 580.142 / Ubuntu 24.04）：

- 完整编译 771 步，0 error
- 启动：`device ready` → 路由校准 49 keys / 39.9s → 权重 12.1 GiB @ 696 MiB/s
- KVMem 环：8.00 GiB host KV pinned / 2.9s
- KV 池：32,768 tokens bf16 / 512 pages / runtime 3.29 GiB / free 3.90 GiB
- context cache：1 active + 1 cached，host 8 states
- 总启动时间：**1m 2.0s**

**没验证的**：

- ❌ 长上下文压测（100K+ 的 prefill 稳定性和耗时）
- ❌ 并发压测
- ❌ MTP 投机解码
- ❌ vision / 多模态
- ❌ `qwen3_8_flash_next` 的**运行**（只用它验证了「编得过」，没跑过；我们用的是 dense 的 `qwen3_5`）
- ❌ Windows ↔ Linux 生成质量的逐 token 对拍
- ❌ `O_DIRECT` 路径在 btrfs 上的表现（该开关默认关闭）

**换句话说**：只证明了「编得过、起得来、池建对」。**生产环境请自行压测。**

---

## 免责声明

- **非官方**。本仓库由社区用户维护，与上游作者无关，不代表上游立场。
- **不保证维护**。上游更新后补丁可能失效，我们可能不会及时跟进。
- **不保证稳定**。上面的「实测边界」就是全部验证范围；未列出的场景都没有测过。
- **不承担任何责任**。使用本仓库的补丁或二进制所造成的任何损失（数据、硬件、业务），与本仓库维护者无关。
- **二进制是按「现状」提供的**，未做代码审计，请自行评估风险。
- 使用时请遵守上游仓库的许可证（Apache-2.0）与模型本身的许可条款。

---

## 致谢

- 上游 [`1314521gjy/ninfer-fusion-kvmem`](https://github.com/1314521gjy/ninfer-fusion-kvmem) —— 引擎本体
- 它的上游 [`ashalliants/ninfer-3090`](https://github.com/ashalliants/ninfer-3090) 与 `Neroued/ninfer`
- 上游 issue 里给出 Linux 编译先例的 `0LEL0`（PR #2）、`Jerry-Lee661`（#11）
