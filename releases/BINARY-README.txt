ninfer-serve — Linux x86_64 预编译二进制
========================================

⚠️ 请先读完这一段再使用。

【这是什么】
  ninfer-fusion-kvmem 引擎的 ninfer-serve，由上游源码 + 本仓库 8 个补丁
  在 GitHub Actions 上编译而成。

  编译环境：
    CUDA     13.3
    GCC      13.3
    宿主      Ubuntu 24.04

【适用 GPU —— 看文件名里的 sm 编号】
  文件名格式：ninfer-serve-linux-x86_64-sm<ARCH>-cuda13.3.tar.gz

    sm86   RTX 30 系：3060 / 3060 Ti / 3070 / 3070 Ti / 3080 / 3080 Ti /
           3090 / 3090 Ti；专业卡 A10 / A40 / A6000 / A5000 等 Ampere
    sm89   RTX 40 系：4060 / 4070 / 4080 / 4090 等 Ada
    sm120  RTX 50 系：5060 / 5070 / 5080 / 5090 等 Blackwell

  ❌ AMD / Intel 显卡不适用。

  不确认的话跑一下：
    nvidia-smi --query-gpu=name,compute_cap --format=csv

  对应表：compute_cap 8.6 -> sm86，8.9 -> sm89，12.0 -> sm120。
  **下错架构的会直接跑不起来。**

【驱动要求】
  镜像要求在驱动 >= 580 上运行（CUDA minor version compatibility）。
  实测环境：驱动 580.142，正常工作。

  注意：如果驱动 < 610，nvidia-container-cli 会因为镜像 metadata
  拒绝挂 GPU，需要手动挂 libcuda.so / libnvidia-ml.so。
  具体命令见仓库 docs/gotchas.md 第 1 节。

【运行期依赖】
  Ubuntu 24.04：
    sudo apt install libavformat60 libavcodec60 libavutil58 libswscale7 libcurl4

  其它发行版请找对应的 soname 版本。
  缺库会报：
    error while loading shared libraries: libavformat.so.60

【快速验证】
  不需要 GPU 和模型，先确认二进制能加载：
    chmod +x ninfer-serve
    ./ninfer-serve --help

  注意：--version 不是有效参数（会被当成模型路径）。
  验证 GPU 通路必须给真实模型：
    ./ninfer-serve /path/to/model.ninfer --port 8089 --host 0.0.0.0 --max-context 32768

【实测验证范围 —— 只有这么多】
  在一台 RTX 3080 20G / 驱动 580.142 / Ubuntu 24.04 上验证了：

    ✅ 完整编译 771 步，0 error
    ✅ 启动到 device ready，路由校准 49 keys / 39.9s
    ✅ 权重加载 12.1 GiB @ 696 MiB/s
    ✅ KVMem 环：8.00 GiB host KV pinned / 2.9s
    ✅ KV 池：32,768 tokens bf16 / 512 pages / runtime 3.29 GiB
    ✅ context cache：1 active + 1 cached，host 8 states
    ✅ HTTP 监听 8089

  启动日志末尾长这样：
    capacity | KV 32,768 tokens, bf16, explicit | pages 512/512 |
               runtime 3.29 GiB | free 3.90 GiB
    listening on http://0.0.0.0:8089

【没有验证的 —— 请自己压测】
  ❌ 长上下文（100K+ prefill 的稳定性和耗时）
  ❌ 并发（--max-concurrency > 1）
  ❌ MTP 投机解码（--spec mtp）
  ❌ vision / 多模态
  ❌ qwen3_8_flash_next（Qwen4 架构预览）的运行时行为
      —— 只用它验证了「能编译通过」，没跑过
  ❌ 与 Windows 版本生成质量的逐 token 对拍
  ❌ O_DIRECT 读路径在 btrfs 上的表现（该开关默认关闭）

  换句话说：只证明了「编得过、起得来、池建对」。
  这是实验性构建，生产环境请务必自行验证。

【免责】
  · 非官方、社区维护，与上游作者无关
  · 不保证维护：上游更新后本二进制即过期
  · 不保证稳定：上面的验证范围就是全部
  · 不承担任何责任：使用风险自负
  · 未做完整代码审计
  · 遵守上游 Apache-2.0 许可与模型自身条款

【校验】
  sha256sum -c SHA256SUMS.txt

【源码与补丁】
  https://github.com/Reiya-Sakuya/ninfer-linux-port
  上游 https://github.com/1314521gjy/ninfer-fusion-kvmem
