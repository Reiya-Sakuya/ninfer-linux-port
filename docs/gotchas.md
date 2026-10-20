# 踩过的坑

按「会让你卡多久」排序。

---

## 1. 驱动 580 + CUDA 13.3

**症状**：`nvidia-container-cli` 直接拒绝挂 GPU：

```
nvidia-container-cli: requirement error: unsatisfied condition: cuda>=13.3,
please update your driver to a newer version, or use an earlier cuda container
```

**原因**：CUDA 13.3 官方对应驱动分支是 R610，而镜像 metadata 写死了 `cuda>=13.3`。

**但这不是死路。** NVIDIA release notes 的小版本兼容条款成立：

> Existing CUDA 13.x applications run on drivers >=580 under CUDA minor version compatibility.

实测 **580.142 + CUDA 13.3 runtime 正常工作**（`device ready`、路由校准 49 keys 全通）。

**绕过办法**：不经过 nvidia runtime 的版本检查，直接用设备节点 + 驱动 `.so`：

```sh
# 先看你的驱动版本
ls /usr/lib/x86_64-linux-gnu/libcuda.so.*

docker run -d --name nf-run \
  --device /dev/nvidiactl --device /dev/nvidia-uvm --device /dev/nvidia0 \
  -v /usr/lib/x86_64-linux-gnu/libcuda.so.580.142:/usr/lib/x86_64-linux-gnu/libcuda.so.1:ro \
  -v /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.580.142:/usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1:ro \
  nvidia/cuda:13.3.0-devel-ubuntu24.04 sleep infinity
```

把 `580.142` 换成你的驱动版本。

> 只想**编译**的话根本不需要 GPU，构建容器不用加 `--device`。

---

## 2. CUDA 必须是 13.3+，上游 Dockerfile 的 13.1.2 编不过

**症状**：

```
qsa_indexer_kernels.cu: fatal error: cub/device/device_topk.cuh: No such file or directory
```

**原因**：代码用了 CCCL 3.2+ 的 API。

| 需要 | CUDA 13.1（CUB 3.1.4） | CUDA 13.3（CUB 3.3.3） |
|---|---|---|
| `cub/device/device_topk.cuh` | ❌ | ✅ |
| `cub::DeviceTopK` | ❌ | ✅ |
| `cuda/__execution/output_ordering.h` | ❌ | ✅ |

**别想着只换头文件。** 我把 CCCL 3.2 的 `cub/` 和 `libcudacxx/` 塞到 13.1 里试过：

```
cub/detail/type_traits.cuh(59): error: identifier "_CCCL_TRAIT" is undefined
cub/detail/type_traits.cuh(69): error: identifier "_CUDA_VSTD" is undefined
```

`cub` 和 `libcudacxx` 是配套的，只换一半会全崩。**直接换整个 CUDA 13.3 镜像。**

---

## 3. gcc-13 必须显式指定

上游 `docs/rtx-3090-linux.md` 写了，但容易漏——漏了会收获一片 SIMD 报错。

```sh
export CC=/usr/bin/gcc-13 CXX=/usr/bin/g++-13
export CUDACXX=/usr/local/cuda/bin/nvcc
export CUDAHOSTCXX=/usr/bin/g++-13      # ← 最容易漏这个

cmake ... \
  -DCMAKE_C_COMPILER=/usr/bin/gcc-13 \
  -DCMAKE_CXX_COMPILER=/usr/bin/g++-13 \
  -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc \
  -DCMAKE_CUDA_HOST_COMPILER=/usr/bin/g++-13    # ← 和上面那个都要
```

---

## 4. 编译目录**必须**在 tmpfs 上（这条最要命）

**CUDA 编译会产生大量小文件写。**

如果 build 目录在 btrfs（或任何 CoW 文件系统）上，实测能把整机 **btrfs transaction 锁死**——
不是慢，是**整台机器卡住，只能硬重启**。

```sh
--tmpfs /tmpfs:size=8g
# 然后 -B /tmpfs/build
```

中间产物实测只有 **1~2 GB**，8G tmpfs 绰绰有余。

`build.sh` 已经默认这么做了。

---

## 5. `--parallel 2` 就是最优，别加

官方文档写的 `--parallel 2` 不是保守，是**实测最优**。

`small_t_i8` 那一段单步极慢（每个 nvcc 进程要展开几十个模板实例），
**加并发没有任何收益**，只会多吃内存：

| 并发 | 那一段的表现 |
|---|---|
| `-j2` | 正常，内存 ~6 GB |
| `-j6` | **速率相同**，内存 ~14 GB，偶发 `cicc` OOM |

上游 issue #11 也报了同一现象：`ninja -j8` 下 8 个 `cicc` 全部 `LLVM ERROR: out of memory`。

**总耗时约 1.5~2 小时，接受它。**

---

## 6. 运行期缺 ffmpeg / curl 库

二进制编译时不静态链接这些，运行时会报：

```
error while loading shared libraries: libavformat.so.60: cannot open shared object file
```

Ubuntu 24.04：

```sh
sudo apt install libavformat60 libavcodec60 libavutil58 libswscale7 libcurl4
```

---

## 附：`ninfer-serve --version` 是假参数

```sh
$ ./ninfer-serve --version
... NInfer accepts only .ninfer artifacts ...
```

它不是不支持 `--version`，而是把 `--version` **当成模型路径**了。

**验证二进制能不能跑，用 `--help`**：

```sh
$ ./ninfer-serve --help
```

要验证 GPU 通路，必须给真实的 `.ninfer` 路径：

```sh
$ ./ninfer-serve /models/xxx.ninfer --port 8089 --host 0.0.0.0 --max-context 32768
```
