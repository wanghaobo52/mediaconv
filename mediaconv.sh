#!/system/bin/sh
# ---------------------------------------------------------------------------
# mediaconv.sh — 音频格式批量互转前端
#
# 配套：同目录下的 libmediacore.so
#   - 该 .so 是一个静态链接的 FFmpeg 转码器，本身就是可执行体
#     （直接 execve 即可运行），所以本脚本直接调用它，无需安装任何其它东西。
#   - 若它被放在 noexec 分区（/sdcard 就是），脚本会自动复制到可执行目录。
#
# 用法：
#   sh mediaconv.sh                     脚本所在目录的音频 → ./转换/（默认转 mp3 320k）
#   sh mediaconv.sh -f flac             转成 FLAC
#   sh mediaconv.sh -f m4a -b 256       转成 AAC 256kbps
#   sh mediaconv.sh -o 输出目录          指定输出目录
#   sh mediaconv.sh -r                  连同子目录一起扫描
#   sh mediaconv.sh -j 4                并发 4 个任务
#   sh mediaconv.sh -i 歌曲.flac         只看音频信息，不转换
#   sh mediaconv.sh --check             环境自检
#
# 输入格式：mp3 flac wav m4a mp4 aac ogg opus wma ape alac mka
# 输出格式（-f）：mp3 flac wav m4a aac ogg
# ---------------------------------------------------------------------------

set -u

PROG=mediaconv.sh
VERSION=1.1

# ---------- 定位脚本目录 ----------
SELF=$0
case $SELF in
    */*) ;;
    *) SELF=./$SELF ;;
esac
DIR=$(CDPATH= cd "$(dirname "$SELF")" 2>/dev/null && pwd) || {
    echo "$PROG: 无法定位脚本目录" >&2
    exit 1
}
ABS_SELF=$DIR/$(basename "$SELF")
ORIG_ARGS="$*"
SO=$DIR/libmediacore.so
[ -f "$SO" ] || SO=$DIR/mediacore.so

OUTDIR=$DIR/转换
RECURSE=0
FORCE=0
JOBS=0
INFO_ONLY=
declare_list=

# ---------- 参数 ----------
ARGN=$#
while [ $# -gt 0 ]; do
    case $1 in
        -h|--help) HELP=1 ;;
        -o) shift; [ $# -gt 0 ] || { echo "$PROG: -o 需要参数" >&2; exit 2; }; OUTDIR=$1 ;;
        -o*) OUTDIR=${1#-o} ;;
        -f) shift; [ $# -gt 0 ] || { echo "$PROG: -f 需要参数" >&2; exit 2; }; FMT=$1 ;;
        -f*) FMT=${1#-f} ;;
        -b) shift; [ $# -gt 0 ] || { echo "$PROG: -b 需要参数" >&2; exit 2; }; BR=$1 ;;
        -b*) BR=${1#-b} ;;
        -ar) shift; [ $# -gt 0 ] || { echo "$PROG: -ar 需要参数" >&2; exit 2; }; AR=$1 ;;
        -ac) shift; [ $# -gt 0 ] || { echo "$PROG: -ac 需要参数" >&2; exit 2; }; AC=$1 ;;
        -c) shift; [ $# -gt 0 ] || { echo "$PROG: -c 需要参数" >&2; exit 2; }; CODEC=$1 ;;
        -j) shift; [ $# -gt 0 ] || { echo "$PROG: -j 需要参数" >&2; exit 2; }; JOBS=$1 ;;
        -i|--info) shift; [ $# -gt 0 ] || { echo "$PROG: -i 需要参数" >&2; exit 2; }; INFO_ONLY=$1 ;;
        -r) RECURSE=1 ;;
        -y) FORCE=1 ;;
        --check) CHECK_ONLY=1 ;;
        -*) echo "$PROG: 未知选项 $1（-h 查看帮助）" >&2; exit 2 ;;
        *) declare_list="$declare_list
$1" ;;
    esac
    shift
done

FMT=${FMT:-mp3}
BR=${BR:-}
AR=${AR:-}
AC=${AC:-}
CODEC=${CODEC:-}

# ---------- 交互向导：一个参数都不给时走这里 ----------
if [ "$ARGN" -eq 0 ] && [ -z "$INFO_ONLY" ] && [ "${CHECK_ONLY:-0}" = 0 ]; then
    printf '\n'
    printf '  音频格式互转 %s\n' "$VERSION"
    printf '  ------------------------------------\n\n'
    printf '  转成什么格式？\n\n'
    printf '    1) MP3  320k   兼容性最好，车机、老设备都认\n'
    printf '    2) M4A  256k   AAC，同码率下音质比 MP3 好\n'
    printf '    3) FLAC 无损   体积大，适合收藏\n'
    printf '    4) WAV  无损   未压缩，体积最大\n'
    printf '    5) OGG  256k   开源 Vorbis\n'
    printf '    6) AAC  256k   裸流，部分播放器不认\n\n'
    printf '  序号 [1]: '
    a=
    read -r a 2>/dev/null || a=
    case $a in
        2) FMT=m4a;  BR=256 ;;
        3) FMT=flac; BR= ;;
        4) FMT=wav;  BR= ;;
        5) FMT=ogg;  BR=256 ;;
        6) FMT=aac;  BR=256 ;;
        *) FMT=mp3;  BR=320 ;;
    esac

    ncpu=$(getconf _NPROCESSORS_ONLN 2>/dev/null)
    case $ncpu in ''|*[!0-9]*) ncpu=4 ;; esac
    if [ "$ncpu" -gt 4 ]; then defj=4; else defj=$ncpu; fi
    printf '\n  同时转几个？本机 %s 核，回车就用 %s [%s]: ' "$ncpu" "$defj" "$defj"
    a=
    read -r a 2>/dev/null || a=
    case $a in
        ''|*[!0-9]*) JOBS=$defj ;;
        *) if [ "$a" -ge 1 ] && [ "$a" -le 16 ]; then JOBS=$a; else JOBS=$defj; fi ;;
    esac

    printf '\n  连子文件夹一起转吗？[y/N]: '
    a=
    read -r a 2>/dev/null || a=
    case $a in
        y|Y|yes|YES) RECURSE=1 ;;
        *) RECURSE=0 ;;
    esac

    printf '\n  ------------------------------------\n'
    printf '  格式 %s' "$FMT"
    [ -n "$BR" ] && printf ' %s kbps' "$BR"
    printf '   并发 %s   递归 ' "$JOBS"
    if [ "$RECURSE" = 1 ]; then printf '是'; else printf '否'; fi
    printf '\n  输出 %s\n\n' "$OUTDIR"
    printf '  开始转换？[Y/n]: '
    a=
    read -r a 2>/dev/null || a=
    case $a in
        n|N|no|NO) printf '\n  已取消，什么都没动。\n'; exit 0 ;;
    esac
    printf '\n'
fi

case $FMT in
    mp3|flac|wav|m4a|aac|ogg) ;;
    *) echo "$PROG: 不支持输出格式 '$FMT'（可选 mp3 flac wav m4a aac ogg）" >&2; exit 2 ;;
esac

# 有损格式给个像样的默认码率；无损格式忽略码率，交给编码器自己挑
if [ -z "$BR" ]; then
    case $FMT in
        mp3)     BR=320 ;;
        m4a|aac) BR=256 ;;
        ogg)     BR=256 ;;
    esac
fi

# 输出目录统一成绝对路径，后面扫输入时要靠它把自己排除掉，
# 否则 -r 会把「转换」里的产物当成新输入，一层层套下去
case $OUTDIR in
    /*) ;;
    *)  OUTDIR=$DIR/$OUTDIR ;;
esac

if [ "${HELP:-0}" = 1 ]; then
    cat <<EOF
$PROG $VERSION — 音频格式批量互转（内置 FFmpeg）

用法:
  sh $PROG                          交互向导（选格式、并发、是否递归）
  sh $PROG [选项] [文件...]          直接按参数跑，不弹询问

不给文件时，处理脚本所在目录里的音频文件，输出到该目录下的「转换」文件夹。
转换时会尽量保留原文件的标签（歌名/歌手/专辑）和封面图；标签丢了可以再用
同目录的 metafix.sh 补回来。

选项:
  -f <格式>   输出格式: mp3 flac wav m4a aac ogg（默认 mp3）
  -b <码率>   输出码率 kbps，如 320（默认 mp3 为 320，m4a/aac 为 256；无损格式忽略）
  -ar <Hz>    输出采样率，如 44100（默认保持原样）
  -ac <声道>  输出声道数，如 2（默认保持原样）
  -c <编码器> 强制指定编码器，如 libmp3lame / flac / aac / vorbis / opus
  -o <目录>   输出目录（默认：./转换）
  -r          递归处理子目录（输出保留子目录结构）
  -j <数量>   并发任务数（默认按 CPU 核心数，最多 4）
  -i <文件>   只显示该文件的音频信息，不转换
  -y          目标文件已存在时也重新转换（默认跳过）
  --check     环境自检
  -h          显示本帮助

依赖: 同目录的 libmediacore.so（必须与 $PROG 放在一起）
配套: 「标签补全」项目 — 转格式丢了的标签可以用它修回来
EOF
    exit 0
fi

# ---------- 找到可执行的核心 ----------
RUN_SO=

try_run() {
    [ -n "$1" ] || return 1
    [ -f "$1" ] || return 1
    "$1" -h >/dev/null 2>&1
}

find_so() {
    [ -f "$SO" ] || return 1
    if try_run "$SO"; then
        RUN_SO=$SO
        return 0
    fi

    parent_pkg=
    if [ -r /proc/$PPID/cmdline ]; then
        parent_pkg=$(tr '\0' '\n' < /proc/$PPID/cmdline 2>/dev/null | head -n 1)
        case $parent_pkg in
            *[!a-zA-Z0-9._]*) parent_pkg= ;;
        esac
    fi

    cand_dirs=
    [ -n "${TMPDIR:-}" ] && cand_dirs="$cand_dirs $TMPDIR"
    [ -n "${PREFIX:-}" ] && cand_dirs="$cand_dirs $PREFIX/tmp"
    [ -n "${HOME:-}" ] && cand_dirs="$cand_dirs $HOME/.cache $HOME/tmp"
    [ -n "$parent_pkg" ] && cand_dirs="$cand_dirs /data/data/$parent_pkg/cache /data/user/0/$parent_pkg/cache"
    cand_dirs="$cand_dirs /data/local/tmp /dev/shm /tmp"

    tried=
    for d in $cand_dirs; do
        [ -d "$d" ] && [ -w "$d" ] || continue
        t=$d/.mediacore.$$
        if cp "$SO" "$t" 2>/dev/null; then
            chmod 700 "$t" 2>/dev/null
            if try_run "$t"; then
                RUN_SO=$t
                trap 'rm -f "$t"' EXIT HUP INT TERM
                return 0
            fi
            rm -f "$t" 2>/dev/null
            tried="$tried $d(不可执行)"
        else
            tried="$tried $d(不可写)"
        fi
    done
    SO_TRIED=$tried
    return 1
}

if [ ! -f "$SO" ]; then
    echo "$PROG: 找不到 $SO" >&2
    echo "请把 libmediacore.so 与本脚本放在同一个文件夹里。" >&2
    exit 1
fi

if [ "${CHECK_ONLY:-0}" = 1 ]; then
    echo "脚本目录 : $DIR"
    echo "当前用户 : $(id)"
    echo "核心文件 : $SO ($(wc -c < "$SO" 2>/dev/null) 字节)"
    if find_so; then
        echo "可直接执行: 是 ($RUN_SO)"
        echo "版本信息  : $("$RUN_SO" -h 2>&1 | head -1)"
        [ "$RUN_SO" = "$SO" ] || rm -f "$RUN_SO" 2>/dev/null
    else
        echo "可直接执行: 否"
        echo "已尝试   :${SO_TRIED:- 无可用目录}"
    fi
    exit 0
fi

SO_TRIED=
if ! find_so; then
    if [ "${MEDIACONV_ELEVATED:-0}" != 1 ] && command -v su >/dev/null 2>&1; then
        echo "该目录不允许执行程序，正在尝试用 root 权限重新运行…" >&2
        MEDIACONV_ELEVATED=1 exec su -c "MEDIACONV_ELEVATED=1 sh '$ABS_SELF' $ORIG_ARGS"
    fi
    echo "$PROG: 无法执行 $SO" >&2
    echo "该目录禁止执行程序（/sdcard 通常是 noexec），且没有找到可写的可执行目录。" >&2
    echo "已尝试:${SO_TRIED:- 无}" >&2
    echo "解决办法（任选其一）：" >&2
    echo "  1. 用 root 运行本脚本；" >&2
    echo "  2. 把脚本和 libmediacore.so 放到 Termux 的 HOME 下运行；" >&2
    echo "  3. 先执行: cp libmediacore.so /data/local/tmp/ && chmod 700 /data/local/tmp/libmediacore.so" >&2
    exit 1
fi

# ---------- 工具函数 ----------
field() {
    printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1
}

clean_name() {
    printf '%s' "$1" \
        | tr -d '\r\n' \
        | sed -e 's#[/\\]#-#g' -e 's#[:*?"<>|]#_#g' \
        | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//'
}

clip_name() {
    printf '%s' "$1" | cut -b1-160
}

# 秒数 → mm:ss
fmt_time() {
    awk -v s="$1" 'BEGIN{ if (s+0<=0){print "-";exit} m=int(s/60); printf "%d:%02d", m, int(s-m*60) }'
}

uniq_path() {
    base=$1
    ext=$2
    cand=$base.$ext
    n=2
    while [ -e "$cand" ]; do
        cand=$base"($n)".$ext
        n=$((n + 1))
    done
    printf '%s' "$cand"
}

# 这些扩展名会被扫描 / 接受
is_audio() {
    case $1 in
        mp3|MP3|flac|FLAC|wav|WAV|m4a|M4A|mp4|MP4|aac|AAC|ogg|OGG|oga|OGA|\
        opus|OPUS|wma|WMA|ape|APE|alac|ALAC|mka|MKA) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------- 只看信息 ----------
if [ -n "$INFO_ONLY" ]; then
    [ -f "$INFO_ONLY" ] || { echo "$PROG: 文件不存在: $INFO_ONLY" >&2; exit 1; }
    raw=$("$RUN_SO" -probe "$INFO_ONLY" 2>&1)
    [ $? -eq 0 ] || { echo "无法解析: $(field "$raw" error)" >&2; exit 1; }
    sz=$(wc -c < "$INFO_ONLY" 2>/dev/null)
    printf '文件      : %s\n' "${INFO_ONLY##*/}"
    printf '容器格式  : %s\n' "$(field "$raw" format)"
    printf '音频编码  : %s\n' "$(field "$raw" codec)"
    printf '采样率    : %s Hz\n' "$(field "$raw" sample_rate)"
    printf '声道数    : %s\n' "$(field "$raw" channels)"
    printf '位深      : %s bit\n' "$(field "$raw" bits)"
    br=$(field "$raw" bit_rate)
    case $br in
        0|"") printf '码率      : 可变（VBR，无固定值）\n' ;;
        *)    printf '码率      : %s kbps\n' "$br" ;;
    esac
    dur=$(field "$raw" duration)
    if [ "$(field "$raw" duration_exact)" = 0 ]; then
        printf '时长      : %s（约，ADTS 容器没有时长信息）\n' "$(fmt_time "$dur")"
    else
        printf '时长      : %s\n' "$(fmt_time "$dur")"
    fi
    printf '文件大小  : %s 字节\n' "${sz:-?}"
    exit 0
fi

# ---------- 收集文件 ----------
TMPBASE=${TMPDIR:-/tmp}
[ -d "$TMPBASE" ] && [ -w "$TMPBASE" ] || TMPBASE=$DIR
LIST=$TMPBASE/.conv_list.$$
: > "$LIST" 2>/dev/null || { echo "$PROG: 无法创建临时列表" >&2; exit 1; }

if [ -n "$declare_list" ]; then
    printf '%s\n' "$declare_list" | sed '/^$/d' >> "$LIST"
elif [ "$RECURSE" = 1 ]; then
    find "$DIR" -path "$OUTDIR" -prune -o -type f \( -iname '*.mp3' -o -iname '*.flac' -o -iname '*.wav' \
        -o -iname '*.m4a' -o -iname '*.mp4' -o -iname '*.aac' -o -iname '*.ogg' \
        -o -iname '*.oga' -o -iname '*.opus' -o -iname '*.wma' -o -iname '*.ape' \
        -o -iname '*.alac' -o -iname '*.mka' \) -print >> "$LIST" 2>/dev/null
else
    for f in "$DIR"/*; do
        [ -f "$f" ] || continue
        [ "${f##*/}" = "${SO##*/}" ] && continue
        [ "${f##*/}" = "${ABS_SELF##*/}" ] && continue
        is_audio "${f##*.}" && printf '%s\n' "$f" >> "$LIST"
    done
fi

total=$(grep -c . "$LIST" 2>/dev/null)
[ -n "$total" ] || total=0
if [ "$total" = 0 ]; then
    rm -f "$LIST"
    echo "$PROG: 没有找到可转换的音频文件"
    exit 0
fi

mkdir -p "$OUTDIR" || { echo "$PROG: 无法创建输出目录 $OUTDIR" >&2; rm -f "$LIST"; exit 1; }

# ---------- 并发数 ----------
if [ "$JOBS" -le 0 ] 2>/dev/null; then
    n=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
    [ -n "$n" ] || n=1
    JOBS=$n
    [ "$JOBS" -gt 4 ] && JOBS=4
    [ "$JOBS" -lt 1 ] && JOBS=1
fi
[ "$total" -lt "$JOBS" ] && JOBS=$total

echo "输入目录: $DIR"
echo "输出目录: $OUTDIR"
echo "目标格式: $FMT${BR:+ $BR kbps}${AR:+ ${AR}Hz}${AC:+ ${AC}声道}"
echo "共 $total 个文件，并发 $JOBS"
echo "------------------------------------------------------------"

# ---------- 单个文件转换 ----------
C_OK=0
C_SKIP=0
C_FAIL=0
FAILED=

convert_one() {
    src=$1
    name=${src##*/}
    ext=${name##*.}
    ext=$(printf '%s' "$ext" | tr 'A-Z' 'a-z')

    # 同格式且未强制 → 跳过，避免 mp3 转 mp3 这种白白损失音质
    if [ "$ext" = "$FMT" ] && [ "$FORCE" != 1 ]; then
        printf '[跳过] %s（已经是 %s）\n' "$name" "$FMT"
        return 2
    fi

    # 输出路径：-r 时保留相对子目录结构
    if [ "$RECURSE" = 1 ]; then
        rel=${src#$DIR/}
        sub=${rel%/*}
        case $sub in
            "$rel") sub= ;;
        esac
        if [ -n "$sub" ] && [ "$sub" != "$rel" ]; then
            outdir=$OUTDIR/$sub
            mkdir -p "$outdir" 2>/dev/null
        else
            outdir=$OUTDIR
        fi
    else
        outdir=$OUTDIR
    fi

    base=$(clean_name "${name%.*}")
    [ -n "$base" ] || base=audio
    base=$(clip_name "$base")
    dst=$outdir/$base.$FMT

    if [ -e "$dst" ] && [ "$FORCE" != 1 ]; then
        printf '[跳过] %s（目标已存在）\n' "${dst##*/}"
        return 2
    fi
    [ -e "$dst" ] && rm -f "$dst"

    # 先写临时文件，成功后再改名，避免半成品。
    # 注意不能只用 $$：mksh 里并行的子进程共享父进程 PID，会撞成同一个名字。
    tmp=$outdir/.conv_$$_${RANDOM}.tmp.$FMT
    set -- "$src" "$tmp"
    [ -n "$BR" ] && set -- "$@" -b "$BR"
    [ -n "$AR" ] && set -- "$@" -ar "$AR"
    [ -n "$AC" ] && set -- "$@" -ac "$AC"
    [ -n "$CODEC" ] && set -- "$@" -c "$CODEC"
    set -- "$@" -q

    if "$RUN_SO" "$@" >/dev/null 2>&1; then
        if mv "$tmp" "$dst" 2>/dev/null; then
            printf '[完成] %s → %s  (%s 字节)\n' "$name" "${dst##*/}" "$(wc -c < "$dst" 2>/dev/null)"
            return 0
        fi
    fi
    rm -f "$tmp"
    err=$("$RUN_SO" "$@" 2>&1 | sed -n 's/^error=//p' | head -1)
    printf '[失败] %s（%s）\n' "$name" "${err:-转换出错}"
    return 1
}

# ---------- 任务分片，每个分片一个后台 worker ----------
if [ "$JOBS" -le 1 ]; then
    idx=0
    while IFS= read -r f; do
        [ -n "$f" ] && [ -f "$f" ] || continue
        convert_one "$f"
        case $? in 0) C_OK=$((C_OK+1));; 2) C_SKIP=$((C_SKIP+1));; *) C_FAIL=$((C_FAIL+1)); FAILED="$FAILED
  ${f##*/}";; esac
    done < "$LIST"
else
    # 把清单按行轮转切成 JOBS 份
    i=0
    while [ $i -lt "$JOBS" ]; do
        i=$((i + 1))
        awk -v n="$JOBS" -v k="$i" 'NR % n == (k-1)' "$LIST" > "$LIST.$i" 2>/dev/null
    done
    i=0
    while [ $i -lt "$JOBS" ]; do
        i=$((i + 1))
        (
            printf '0 0 0\n' > "$LIST.$i.cnt"
            ok=0; sk=0; fa=0
            while IFS= read -r f; do
                [ -n "$f" ] && [ -f "$f" ] || continue
                convert_one "$f"
                case $? in
                    0) ok=$((ok+1));;
                    2) sk=$((sk+1));;
                    *) fa=$((fa+1)); printf '%s\n' "${f##*/}" >> "$LIST.$i.fail";;
                esac
            done < "$LIST.$i"
            printf '%s %s %s\n' "$ok" "$sk" "$fa" > "$LIST.$i.cnt"
        ) &
    done
    wait
    i=0
    while [ $i -lt "$JOBS" ]; do
        i=$((i + 1))
        set -- $(cat "$LIST.$i.cnt" 2>/dev/null)
        C_OK=$((C_OK + ${1:-0}))
        C_SKIP=$((C_SKIP + ${2:-0}))
        C_FAIL=$((C_FAIL + ${3:-0}))
        if [ -f "$LIST.$i.fail" ]; then
            FAILED="$FAILED$(sed 's/^/\
  /' "$LIST.$i.fail")"
        fi
        rm -f "$LIST.$i" "$LIST.$i.cnt" "$LIST.$i.fail"
    done
fi

rm -f "$LIST"

echo "------------------------------------------------------------"
echo "成功 $C_OK 个，跳过 $C_SKIP 个，失败 $C_FAIL 个"
if [ -n "$FAILED" ]; then
    echo "以下文件未能转换：$FAILED"
    exit 1
fi
exit 0
