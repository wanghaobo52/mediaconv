# 音频格式互转

一个脚本 + 一个同目录的核心库，把文件夹里的音频批量转成另一种格式，转换时**保留
歌名/歌手/专辑和封面图**；标签丢了用隔壁「标签补全」项目补回来。

## 文件

| 文件 | 作用 |
|---|---|
| `mediaconv.sh` | 转格式的入口脚本 |
| `libmediacore.so` | 静态链接的 FFmpeg（含 LAME），实际干活 |

两个必须放在同一个文件夹里。`.so` 其实不是动态库，是个完整的静态二进制，只是沿用
这个扩展名。

## 转格式

把要转的歌和这两个文件放一起，然后运行：

    sh mediaconv.sh

不给参数时会走交互向导：先选格式，再选并发数，最后问要不要连子文件夹一起转，
确认后才开始。

想跳过询问、直接按参数跑：

    sh mediaconv.sh -f flac           # 转 FLAC 无损
    sh mediaconv.sh -f m4a            # 转 AAC（256kbps）
    sh mediaconv.sh -f m4a -b 192     # 指定码率
    sh mediaconv.sh -f wav            # 转 WAV
    sh mediaconv.sh -f ogg            # 转 Vorbis
    sh mediaconv.sh -r                # 递归子目录，输出保留目录结构
    sh mediaconv.sh -j 6              # 6 个并发（默认 min(核数,4)）
    sh mediaconv.sh -o 我的输出        # 换输出目录（默认 ./转换）
    sh mediaconv.sh -i 某首歌.flac     # 只看信息，不转换
    sh mediaconv.sh --check           # 自检核心库能不能跑

## 标签补全

转格式会重新编码，标签和封面不一定跟得过来。补标签用旁边的 **「标签补全」** 项目
（`AI工作区/标签补全/`），那个项目专门做这件事，不重新编码，音频数据一个字节都
不动：

    sh metafix.sh -r 音乐目录/          # 按文件名补全整个目录
    sh metafix.sh -n -r 目录/           # 只体检，列出缺什么

## 支持的格式

输入：mp3 flac wav m4a mp4 aac ogg oga opus wma ape alac mka
输出：mp3 flac wav m4a aac ogg

## 几点说明

**标签和封面会一起带过去。** 转格式时歌名、歌手、专辑、年份、风格、音轨号都
会复制到新文件，封面图（mp3 里的那张专辑图）也会。只有 ogg 不支持内嵌封面，
所以转 ogg 时封面会丢，标签还在。

**采样率会自动适配。** MP3 最高只支持 48kHz，96kHz 的母带转 mp3 时会自动降到
48kHz 并给出提示。这是格式本身的限制。

**已经是目标格式的文件会跳过**，不会重复编码损耗音质。想强制重转加 `-y`。

**`.aac` 的时长可能显示得很离谱。** ADTS 容器没有全局头，时长只能按首帧码率
估算，首帧若是静音就会估偏。文件本身是好的，转成 `.m4a` 就正常了。

**为什么不在原地直接运行。** 安卓的 `/sdcard` 是 noexec，不允许执行里面的程序。
脚本会自动把核心库复制到可执行的临时目录再运行，用完删掉，所以第一次会略慢。

**转换中断不会留下半成品。** 先写临时文件，成功后才改名。

## 技术细节

- FFmpeg 7.1 静态构建，只编入需要的解码器、编码器、复用器
- 编码器：libmp3lame 3.100、AAC、FLAC、ALAC、Vorbis、Opus、PCM
- 解码器：MP3、AAC、FLAC、Vorbis、Opus、ALAC、WMA v2、APE、PCM 全系
- musl 静态链接，不依赖系统库
- 标签按容器分别处理：ID3（mp3）、Vorbis comment（flac/ogg）、iTunes atom（m4a）
- 封面图从 mp3 的 APIC、flac 的 picture block、m4a 的 covr atom 之间互通
