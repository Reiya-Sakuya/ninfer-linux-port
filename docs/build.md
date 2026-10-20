# 手动编译步骤

不想用 `build.sh` 的话，照这个走。

以下命令都在 **CUDA 13.3 容器内**执行。

---

## 0. 起构建容器

```sh
docker run -d --name ninfer-build \
  --memory 16g --memory-swap 16g \
  --tmpfs /tmpfs:size=8g \
  -v /path/to/fusion-engine-src:/src:ro \
  nvidia/cuda:13.3.0-devel-ubuntu24.04 sleep infinity
```

> `--tmpfs` 不是可选项，见 [gotchas #4](gotchas.md)。

## 1. 装工具链

```sh
docker exec ninfer-build bash -c '
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    cmake ninja-build gcc-13 g++-13 pkg-config \
    libavcodec-dev libavformat-dev libavutil-dev libswscale-dev libcurl4-openssl-dev
'
```

## 2. 应用补丁

补丁要写文件，而 `/src` 是只读挂载的，所以先拷一份：

```sh
mkdir -p /tmp/ninfer/src
cp -a /path/to/fusion-engine-src/. /tmp/ninfer/src/
./apply.sh /tmp/ninfer/src
```

然后把 `/tmp/ninfer/src` 挂进去（或直接用 `build.sh`，它替你做好这些）。

## 3. 配置

```sh
docker exec ninfer-build bash -c '
  export CC=/usr/bin/gcc-13 CXX=/usr/bin/g++-13
  export CUDACXX=/usr/local/cuda/bin/nvcc CUDAHOSTCXX=/usr/bin/g++-13
  cd /src
  cmake -S . -B /tmpfs/build -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=/usr/bin/gcc-13 \
    -DCMAKE_CXX_COMPILER=/usr/bin/g++-13 \
    -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc \
    -DCMAKE_CUDA_HOST_COMPILER=/usr/bin/g++-13 \
    -DCMAKE_CUDA_ARCHITECTURES=86 \
    -DNINFER_BUILD_APPS=ON -DBUILD_TESTING=OFF -DNINFER_BUILD_BENCHMARKS=OFF
'
```

`-DCMAKE_CUDA_ARCHITECTURES` 按你的卡改：

| GPU | arch |
|---|---|
| RTX 30 系 / A10 / A6000 | `86` |
| RTX 40 系 | `89` |
| RTX 50 系 | `120` |
| 一次编多个 | `86;89` |

## 4. 编译

```sh
docker exec ninfer-build bash -c '
  export CC=/usr/bin/gcc-13 CXX=/usr/bin/g++-13
  export CUDACXX=/usr/local/cuda/bin/nvcc CUDAHOSTCXX=/usr/bin/g++-13
  cmake --build /tmpfs/build --parallel 2
'
```

**约 1.5~2 小时。** 建议后台跑：

```sh
docker exec -d ninfer-build bash -c '
  export CC=/usr/bin/gcc-13 CXX=/usr/bin/g++-13
  export CUDACXX=/usr/local/cuda/bin/nvcc CUDAHOSTCXX=/usr/bin/g++-13
  cd /src && cmake --build /tmpfs/build --parallel 2 > /tmpfs/build.log 2>&1
'
# 看进度：
docker exec ninfer-build sh -c 'grep -oE "^\[[0-9]+/[0-9]+\]" /tmpfs/build.log | tail -1'
```

一共 **771 步**。

## 5. 收产物

```sh
docker cp ninfer-build:/tmpfs/build/apps/ninfer-serve ./ninfer-serve
chmod +x ninfer-serve
```

853 MB 左右。

## 6. 验证

```sh
# 能否加载（不需要 GPU）
./ninfer-serve --help

# 能否用 GPU（需要真实 .ninfer 模型）
./ninfer-serve /path/to/model.ninfer --port 8089 --host 0.0.0.0 --max-context 32768
```

**注意 `--version` 不是有效参数**，会被当成模型路径。见 [gotchas 附录](gotchas.md)。

---

## 只编某个目标

```sh
cmake --build /tmpfs/build --parallel 2 --target ninfer-serve
```

比全量快很多（跳过 `tools/` 下的辅助程序）。
