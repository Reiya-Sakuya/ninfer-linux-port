# 每个补丁在做什么

8 个补丁，按「上游该不该收」分类。

---

## 类别 A：上游真 bug（与操作系统无关）

### 1. `runtime_plan.cpp` — `size_t` / `uint64_t` 推导失败

```cpp
checked_mul(36ULL, single_gdn_conv)   // single_gdn_conv 是 std::size_t
```

`checked_mul` 签名是 `(std::uint64_t, std::uint64_t, std::string_view)`。

| 平台 | `size_t` 实际类型 | 结果 |
|---|---|---|
| Windows（LLP64） | `unsigned long long` = `uint64_t` | 编过 |
| Linux（LP64） | `unsigned long` ≠ `uint64_t` | **模板推导失败** |

```
runtime_plan.cpp(129): error: no matching function for call to
  'checked_mul(long long unsigned int, const std::size_t&)'
```

**为什么这是遗漏不是设计**：同一个文件 105-122 行有十几处调用**本来就写了**
`checked_mul<std::size_t>(...)` 显式模板参数，只有 129 / 162 行那几处漏了。

**修法**：补上显式模板参数，与同文件其余部分一致。运行期语义零变化。

### 2. `apps/CMakeLists.txt` — 静态库循环依赖

```
ninfer_engine ──links──▶ ninfer_model_runtime ──links──▶ ninfer_model_loading
      ▲                            │                            │
      └────────────────────────────┴────────────────────────────┘

model_runtime 的 program.cpp        → runtime::OutputConstraintState（engine 里实现）
model_loading 的 materialized.cpp   → flash_next_* 函数（model_runtime 里实现）
```

- **MSVC 链接器**：反复扫描 archive，环自然解决
- **GNU ld**：单遍扫描，所有反向引用报 undefined reference

**不是漏编文件**。符号表确认 `structured_output.cpp.o` 里 18 个 `OutputConstraintState`
符号全是 `T`（全局导出），`src/runtime/CMakeLists.txt:33` 也确实列了这个源文件。

**修法**：`$<LINK_GROUP:RESCAN,...>`，这是 MSVC 隐式行为的可移植表达。
三个库必须一起进组（两个方向的环）。

---

## 类别 B：编译器差异（MSVC 宽容，GCC 严格）

### 3. `gdn.cpp` — 缺 `<algorithm>`

```cpp
std::max({a, b, c})
```

MSVC 间接包含 `<algorithm>`，GCC 不包含。

### 4. `moe_kernels.cu` — `alignas` 用在 `extern __shared__`

```cpp
extern __shared__ alignas(16) std::uint8_t s_dyn_mem[];
// error: attribute "alignas" does not apply to any entity
```

**去掉是安全的**：CUDA 保证动态共享内存起始地址 16 字节对齐，
下面所有基于偏移的指针算术完全不变。共 2 处。

### 5. `cpu_expert_nvfp4.h` — 166 处 SIMD intrinsics

**这条跟 Windows 无关**，是 target 检查策略差异：

- **MSVC**：默认假设调的指令 CPU 都支持，对 `always_inline` 不检查 target
- **GCC**：严格检查内联函数的 target 是否匹配编译选项

用到的指令集：SSSE3（`_mm_shuffle_epi8`）、AVX2、**AVX-VNNI**（`_mm256_dpbusd_avx_epi32`）。

```
cpu_expert_nvfp4.h(309): error: inlining failed in call to 'always_inline'
  _mm_shuffle_epi8(...): target specific option mismatch
```

**修法遵循上游自己的设计**：文件里 `isa_flags()` 在 `#if defined(_MSC_VER)` 之外
直接返回全 -1，注释写着 **"non-MSVC returns -1 (scalar only)"** ——
作者本意就是让非 MSVC 走纯标量。

所以只需让编译器**允许生成**这些指令，运行期交给 `isa_supported()` 守卫：

```cpp
#if defined(__GNUC__) && !defined(_MSC_VER)
#pragma GCC target("ssse3,sse4.1,avx,avx2,avxvnni")
#endif
```

**一行覆盖 166 处，代码逻辑一个字符没动。**

> **顺带一提**：因为 `isa_flags()` 在 GCC 下恒返回 -1，Linux 上**永远走 `kScalar` 标量路径**，
> 用不到 AVX2 加速。如果想让 Linux 也吃到 SIMD 加速，需要把 `isa_flags()` 的 GCC 分支
> 用 `__builtin_cpu_supports` 补上——但这**超出了「移植」的范围**，属于新功能，本仓库不做。

---

## 类别 C：Win32 → POSIX 真等价实现

### 6. `expert_staging.cpp` — `GetProcessIoCounters`

纯统计（「这个 staging 窗口从磁盘读了多少」），原代码失败时本就返回 0 并明说。

Linux 侧用 `/proc/self/io` 的 `read_bytes`。

### 7. `load/materialized.cpp` — 3 处 Win32

| API | 作用 | 默认状态 |
|---|---|---|
| `PrefetchVirtualMemory` | 专家权重预读进页缓存 | `NINFER_FLASH_NEXT_PIN_PREFETCH`，**默认 OFF** |
| `CreateFileW` + `ReadFile`（`FILE_FLAG_NO_BUFFERING`） | 多句柄并行直读 | `NINFER_FLASH_NEXT_PIN_READFILE`，**默认 0** |
| `VirtualQuery` → `MEM_IMAGE`/`MEM_MAPPED`/`MEM_PRIVATE` | 打印内存类型 | 纯诊断 |

**Linux 侧用的是真等价实现，不是空壳**：

| Win32 | Linux 等价 | 说明 |
|---|---|---|
| `PrefetchVirtualMemory(h, 1, &range, 0)` | `madvise(addr, len, MADV_WILLNEED)` | 直接对映射区间下建议，**不需要 fd** |
| `CreateFileW` + `ReadFile` | `open(O_RDONLY\|O_DIRECT)` + `pread` | 每句柄独立 offset |
| `GetProcessIoCounters(ReadTransferCount)` | `/proc/self/io` 的 `read_bytes` | 同为「本进程从块设备实读字节」 |
| `VirtualQuery` | `/proc/self/maps` 反查 | 返回同样三种分类 |

**已知边界**：`O_DIRECT` 在 btrfs 上有 4K 对齐要求，且 btrfs 的 O_DIRECT 支持历史上有争议。
**但这条路径默认关闭**，不影响正常使用。

---

## 类别 D：Windows 独有概念

### 8. `apps/cli/main.cpp` — EcoQoS 限速豁免

上游这段（注释日期 2026-10-14）向 Windows 申请「不接受 EcoQoS 后台降速」，
作者实测 **decode +22.3%、load -19%**。

**Linux 没有这个概念**——CFS 不会因为进程在后台就降速，**没有可豁免的对象**。

所以正确的移植是「不适用」，而不是编造一个等价物：

```
flash_next power_exempt=0 set=not_requested verdict=NOT_APPLICABLE
```

开关仍然解析、仍然默认 OFF，调用点位置一字不动。

> **明确排除的修法**：不伪造 `EXEMPT` / `THROTTLED` 等 verdict。
> 那会让日志撒谎，而这条日志存在的意义恰恰是自证。

---

## 为什么只有 8 个文件

上游的跨平台设计**本来就是完整的**。这些文件全都有干净的 `#ifdef _WIN32` 双路径：

```
src/artifact/file_io.cpp              src/core/host_memory.cpp
src/artifact/reader.cpp               src/core/arena.cu            (含 NINFER_D3D12_RESIDENCY 开关)
src/core/disk_kv_store.cpp            src/core/direct_storage_reader.cpp  (含 NINFER_DIRECTSTORAGE 开关)
src/product/log_colour/log_colour.h   src/product/logging/startup_log.cpp
```

**不兼容 Linux 的只有两处，都是后加的、漏了条件编译**：

1. `qwen3_8_flash_next` 模块（2026-10-19 合并）
2. `apps/cli/main.cpp` 的 EcoQoS（2026-10-14 加入）

所以**核心引擎、KVMem 环、`qwen3_5` 后端一行未动**。
这不是「给 Windows 项目做移植」，是「补上漏掉的几条 `#ifdef`」。
