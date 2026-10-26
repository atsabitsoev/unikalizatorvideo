#!/bin/bash
#
# Уникализатор видео для Instagram (macOS).
#
# Из одного видео делает N копий (по умолчанию 20). Каждая копия получает свой
# случайный набор мелких изменений, незаметных при обычном просмотре, но
# меняющих то, на что смотрят алгоритмы поиска дубликатов:
#   - геометрия: зум 5–8% со сдвигом кадра, поворот на доли градуса, лёгкая
#     перспектива — главное средство против перцептивных хешей вроде PDQ;
#   - время: скорость ±1.5–3% (тон голоса сохраняется), обрезка пары кадров;
#   - цвет: яркость, контраст, гамма, насыщенность, оттенок, едва видимое
#     низкочастотное «световое поле», лёгкое зерно и резкость;
#   - звук: высота тона ±0.5–1.2%, громкость, эквалайзер, частота дискретизации;
#   - файл: полное перекодирование, удаление всех метаданных исходника.
#
# Использование: unikalizator.sh [опции] видео.mp4 [ещё.mov ...]
#   -n, --count N       сколько копий сделать (по умолчанию 20)
#   -s, --strength S    light | normal | strong (по умолчанию normal)
#   -o, --outdir DIR    куда сохранять (по умолчанию — рядом с исходником)
#   -j, --jobs N        сколько копий кодировать параллельно (по умолчанию авто)
#   -e, --encoder E     auto | videotoolbox | x264 (по умолчанию auto)
#       --mirror        зеркалить каждую вторую копию (заметно на тексте!)
#       --seed N        зерно генератора случайных чисел (для повторяемости)
#       --gui           режим Finder: уведомления macOS вместо вывода в терминал
#   -h, --help          эта справка

# Весь скрипт — один блок { … }: bash разбирает его целиком до запуска, поэтому
# обновление файла (повторный install.sh) не ломает уже идущую обработку.
{

VERSION="1.0.0"

APP_DIR="$HOME/Library/Application Support/Unikalizator"
SETTINGS="${UNIK_SETTINGS:-$APP_DIR/settings.conf}"
LOG="${UNIK_LOG:-$HOME/Library/Logs/Unikalizator.log}"

# Значения по умолчанию; settings.conf и опции командной строки их переопределяют.
COUNT=20
STRENGTH=normal
MIRROR=0
ENCODER=auto
JOBS=auto
MAX_SIDE=1080      # короткая сторона кадра не больше этого (как у Instagram)
SUFFIX="_uniq_"    # video.mp4 -> video_uniq_01.mp4
SUBFOLDER=0        # 1 = складывать копии в папку «<имя>_uniq» рядом с исходником
OUTDIR=""
SEED=""
GUI=0

# Десятичная точка в printf/awk должна быть точкой при любой локали.
if [ -n "${LC_ALL:-}" ]; then export LANG="$LC_ALL"; unset LC_ALL; fi
export LC_NUMERIC=C

# Automator запускает скрипты с урезанным PATH — добавляем места, где живёт ffmpeg.
export PATH="$APP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

# shellcheck source=/dev/null
[ -f "$SETTINGS" ] && . "$SETTINGS"

# ---------------------------------------------------------------- сообщения --

say() { [ "$GUI" = 1 ] || printf '%s\n' "$*"; }

log() {
    mkdir -p "$(dirname "$LOG")" 2>/dev/null
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null
}

notify() { # заголовок, текст
    [ "$GUI" = 1 ] || return 0
    command -v osascript >/dev/null || return 0
    osascript -e 'on run argv' \
        -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
        -e 'end run' "$1" "$2" >/dev/null 2>&1
}

alert() { # текст
    if [ "$GUI" = 1 ] && command -v osascript >/dev/null; then
        osascript -e 'on run argv' \
            -e 'display alert "Уникализатор" message (item 1 of argv) as critical' \
            -e 'end run' "$1" >/dev/null 2>&1 || notify "Уникализатор" "$1"
    else
        printf 'Ошибка: %s\n' "$1" >&2
    fi
}

die() { log "ERROR: $1"; alert "$1"; exit 1; }

chime() {
    [ "$GUI" = 1 ] || return 0
    [ -f /System/Library/Sounds/Glass.aiff ] && (afplay /System/Library/Sounds/Glass.aiff >/dev/null 2>&1 &)
}

usage() { sed -n '/^# Использование/,/^#   -h/p' "$0" | sed 's/^# \{0,1\}//'; }

# ------------------------------------------------------------------ опции --

FILES=()
while [ $# -gt 0 ]; do
    case "$1" in
        -n|--count|-s|--strength|-o|--outdir|-j|--jobs|-e|--encoder|--seed)
            [ $# -ge 2 ] || { usage >&2; exit 2; } ;;
    esac
    case "$1" in
        -n|--count)    COUNT="$2"; shift 2 ;;
        -s|--strength) STRENGTH="$2"; shift 2 ;;
        -o|--outdir)   OUTDIR="$2"; shift 2 ;;
        -j|--jobs)     JOBS="$2"; shift 2 ;;
        -e|--encoder)  ENCODER="$2"; shift 2 ;;
        --mirror)      MIRROR=1; shift ;;
        --seed)        SEED="$2"; shift 2 ;;
        --gui)         GUI=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        -v|--version)  echo "unikalizator $VERSION"; exit 0 ;;
        --)            shift; while [ $# -gt 0 ]; do FILES+=("$1"); shift; done ;;
        -*)            usage >&2; exit 2 ;;
        *)             FILES+=("$1"); shift ;;
    esac
done

[ ${#FILES[@]} -gt 0 ] || { usage >&2; exit 2; }

case "$COUNT" in ''|*[!0-9]*) die "Количество копий должно быть числом, а не «$COUNT»." ;; esac
[ "$COUNT" -ge 1 ] && [ "$COUNT" -le 999 ] || die "Количество копий должно быть от 1 до 999."
case "$STRENGTH" in light|normal|strong) ;; *) die "Сила должна быть light, normal или strong, а не «$STRENGTH»." ;; esac
case "$ENCODER" in auto|videotoolbox|x264) ;; *) die "Кодировщик должен быть auto, videotoolbox или x264." ;; esac
case "$MAX_SIDE" in ''|*[!0-9]*) MAX_SIDE=1080 ;; esac

if [ "$JOBS" = auto ]; then
    ncpu=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
    JOBS=$(( (ncpu + 2) / 4 ))
fi
case "$JOBS" in ''|*[!0-9]*) JOBS=2 ;; esac
[ "$JOBS" -lt 1 ] && JOBS=1
[ "$JOBS" -gt 6 ] && JOBS=6

# ------------------------------------------------------------------ ffmpeg --

command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null ||
    die "Не найден ffmpeg. Запустите install.sh из папки уникализатора ещё раз — он установит ffmpeg."

FILTERS=$(ffmpeg -hide_banner -filters 2>/dev/null)
has_filter() { printf '%s\n' "$FILTERS" | grep -qE "^ *[^ =]+ +$1 +"; }
for f in perspective eq hue geq blend unsharp noise fps setpts asetrate atempo aresample equalizer; do
    has_filter "$f" || die "В установленном ffmpeg нет фильтра «$f». Нужна полная сборка ffmpeg (brew install ffmpeg)."
done

ENCODERS=$(ffmpeg -hide_banner -encoders 2>/dev/null)
has_encoder() { printf '%s\n' "$ENCODERS" | grep -qE "^ *[^ =]+ +$1 +"; }

if [ "$ENCODER" = auto ]; then
    if has_encoder h264_videotoolbox; then ENCODER=videotoolbox; else ENCODER=x264; fi
fi
[ "$ENCODER" = x264 ] && ! has_encoder libx264 && die "В установленном ffmpeg нет кодировщика libx264."
[ "$ENCODER" = videotoolbox ] && ! has_encoder h264_videotoolbox && die "В установленном ffmpeg нет кодировщика h264_videotoolbox."

# -------------------------------------------------------- разбор исходника --

# Заполняет переменные SRC_* для файла $1.
probe() {
    local in="$1" line k v rot=0 sar="1/1"
    SRC_W=""; SRC_H=""; SRC_FPS=""; SRC_RFPS=""; SRC_DUR=""; SRC_TRC=""; SRC_PRIM=""; SRC_SPACE=""
    SRC_AUDIO=0; SRC_SR=44100

    while IFS='=' read -r k v; do
        case "$k" in
            width) SRC_W="$v" ;;
            height) SRC_H="$v" ;;
            avg_frame_rate) SRC_FPS="$v" ;;
            r_frame_rate) SRC_RFPS="$v" ;;
            color_transfer) SRC_TRC="$v" ;;
            color_primaries) SRC_PRIM="$v" ;;
            color_space) SRC_SPACE="$v" ;;
            rotation|TAG:rotate) rot="${v%%.*}" ;;
            duration) case "$v" in [0-9]*) [ -z "$SRC_DUR" ] && SRC_DUR="$v" ;; esac ;;
        esac
    done < <(ffprobe -v error -select_streams v:0 \
        -show_entries format=duration:stream=width,height,avg_frame_rate,r_frame_rate,color_transfer,color_primaries,color_space,duration:stream_side_data=rotation:stream_tags=rotate \
        -of default=nw=1 "$in" 2>/dev/null)

    [ -n "$SRC_W" ] && [ -n "$SRC_H" ] || return 1

    # Размер кадра в том виде, в котором его увидят фильтры (после автоповорота
    # телефонного видео) — надёжнее всего спросить у самого ffmpeg.
    line=$(ffmpeg -hide_banner -nostdin -v info -i "$in" -frames:v 1 -an -sn -dn \
        -vf showinfo -f null - 2>&1 | grep -m1 -E 'showinfo.* s:[0-9]+x[0-9]+')
    v=$(printf '%s\n' "$line" | sed -nE 's/.* s:([0-9]+)x([0-9]+).*/\1x\2/p')
    if [ -n "$v" ]; then
        SRC_W="${v%x*}"; SRC_H="${v#*x}"
        sar=$(printf '%s\n' "$line" | sed -nE 's/.* sar:([0-9]+\/[0-9]+).*/\1/p')
        [ -n "$sar" ] || sar="1/1"
    else
        case "$rot" in 90|-90|270|-270) v="$SRC_W"; SRC_W="$SRC_H"; SRC_H="$v" ;; esac
    fi

    # Неквадратные пиксели: приводим к квадратным.
    case "$sar" in
        0/*|*/0|1/1) ;;
        *) SRC_W=$(( SRC_W * ${sar%/*} / ${sar#*/} )) ;;
    esac

    while IFS='=' read -r k v; do
        case "$k" in
            sample_rate) SRC_AUDIO=1; SRC_SR="$v" ;;
        esac
    done < <(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of default=nw=1 "$in" 2>/dev/null)
    case "$SRC_SR" in ''|*[!0-9]*) SRC_SR=44100 ;; esac
    return 0
}

# Частота кадров результата: стандартная ближайшая, если исходник «почти» стандартный.
pick_fps() {
    awk -v a="$1" -v r="$2" 'function val(s,  p) { p = index(s, "/"); if (p == 0) return s + 0; if (substr(s, p + 1) + 0 == 0) return 0; return substr(s, 1, p - 1) / substr(s, p + 1) }
    BEGIN {
        f = val(a); if (f < 1 || f > 400) f = val(r); if (f < 1 || f > 400) f = 30
        if (f > 60.5) f = 60
        n = split("24000/1001 24 25 30000/1001 30 50 60000/1001 60", c, " ")
        best = ""; bd = 1
        for (i = 1; i <= n; i++) { d = val(c[i]) / f - 1; if (d < 0) d = -d; if (d < bd) { bd = d; best = c[i] } }
        if (bd < 0.012) print best; else printf "%.3f\n", f
    }'
}

# -------------------------------------------------- генерация параметров --

# Печатает по строке на копию: присваивания VAR='значение' для eval.
# Каждый параметр раскладывается по копиям «латинским гиперкубом»: диапазон
# делится на N равных частей и каждая копия получает значение из своей части —
# так копии гарантированно отличаются не только от оригинала, но и друг от друга.
gen_params() { # count seed strength mirror W H srcSR
    awk -v n="$1" -v seed="$2" -v strength="$3" -v mirror="$4" -v W="$5" -v H="$6" -v sr="$7" '
    function perm(name,   i, j, t) {
        for (i = 1; i <= n; i++) P[name, i] = i
        for (i = n; i > 1; i--) { j = int(rand() * i) + 1; t = P[name, i]; P[name, i] = P[name, j]; P[name, j] = t }
    }
    function u(name, i) { if (!((name, 1) in P)) perm(name); return (P[name, i] - 1 + rand()) / n }
    function lerp(a, b, t) { return a + (b - a) * t }
    # модуль из [a, b], знак — половине копий плюс, половине минус
    function sgn(a, b, t) { return t < 0.5 ? -lerp(a, b, t * 2) : lerp(a, b, (t - 0.5) * 2) }
    function clamp(x, lo, hi) { return x < lo ? lo : (x > hi ? hi : x) }
    function abs(x) { return x < 0 ? -x : x }
    function r6(x) { return sprintf("%.6f", x) }
    function r3(x) { return sprintf("%.3f", x) }
    BEGIN {
        srand(seed); PI = atan2(0, -1)
        #            light    normal   strong
        split("1.035    1.050    1.075", z1, " ")  # зум (с учётом нужного для поворота)
        split("1.050    1.080    1.100", z2, " ")
        split("0.05     0.10     0.30",  ro1, " ") # поворот, градусы
        split("0.20     0.35     0.80",  ro2, " ")
        split("0.002    0.003    0.006", ks, " ")  # перспектива: сдвиг углов, доля кадра
        split("0.008    0.015    0.030", sp1, " ") # скорость, доля
        split("0.018    0.030    0.055", sp2, " ")
        split("0.07     0.12     0.25",  ts2, " ") # обрезка начала, с (от 0.02)
        split("0.15     0.25     0.40",  te2, " ") # обрезка конца, с
        split("0.004    0.008    0.015", br1, " ") # яркость
        split("0.012    0.022    0.040", br2, " ")
        split("0.010    0.020    0.040", ct1, " ") # контраст
        split("0.025    0.045    0.080", ct2, " ")
        split("0.020    0.030    0.060", sa1, " ") # насыщенность
        split("0.045    0.070    0.120", sa2, " ")
        split("0.010    0.020    0.040", ga1, " ") # гамма
        split("0.025    0.045    0.080", ga2, " ")
        split("0.5      1.0      2.0",   hu1, " ") # оттенок, градусы
        split("1.8      3.0      6.0",   hu2, " ")
        split("1.5      2.5      4.0",   fa1, " ") # световое поле, уровни яркости из 255
        split("2.5      4.0      6.0",   fa2, " ")
        split("0        1        2",     gr1, " ") # зерно
        split("1        3        5",     gr2, " ")
        split("0.003    0.005    0.010", pi1, " ") # высота тона, доля
        split("0.007    0.012    0.022", pi2, " ")
        split("0.5      1.0      2.0",   eq2, " ") # эквалайзер, дБ (от 0.3)
        k = strength == "light" ? 1 : (strength == "strong" ? 3 : 2)

        ratio = W > H ? W / H : H / W
        jit = ks[k] * (W < H ? W : H)
        # Точка 0 — сам оригинал: копии должны быть далеко и от него.
        TX[0] = 0; TY[0] = 0; Z[0] = 1; T[0] = 0; FL[0] = -1
        for (i = 1; i <= n; i++) {
            # --- геометрия. Из 300 случайных кандидатов (зум, поворот, сдвиг)
            # берём самый далёкий от оригинала и уже выбранных копий. Веса —
            # из замеров PDQ: 1% сдвига кадра ≈ 22, 1% зума ≈ 9, 1° поворота ≈ 18
            # единиц расстояния (порог совпадения — 31). Поэтому главное — сдвиг.
            flip = (mirror == 1 && i % 2 == 0) ? 1 : 0
            best = -1
            for (cand = 1; cand <= 300; cand++) {
                td = sgn(ro1[k], ro2[k], rand()); t = td * PI / 180
                c = cos(abs(t)); s = sin(abs(t))
                zz = lerp(z1[k], z2[k], rand())
                zmin = c + ratio * s + 0.012
                if (zz < zmin) zz = zmin
                hw = W / (2 * zz); hh = H / (2 * zz)
                # запас для сдвига, чтобы повёрнутая рамка не вышла за кадр
                mx = W / 2 - (hw * c + hh * s) - jit; if (mx < 0) mx = 0
                my = H / 2 - (hw * s + hh * c) - jit; if (my < 0) my = 0
                sx = (rand() * 2 - 1) * mx; sy = (rand() * 2 - 1) * my
                tx = 100 * sx / W; ty = 100 * sy / H
                d = 1e9
                for (j = 0; j < i; j++) {
                    if (j > 0 && FL[j] != flip) continue
                    e = sqrt((22 * (tx - TX[j])) ^ 2 + (22 * (ty - TY[j])) ^ 2 + (900 * (zz - Z[j])) ^ 2 + (18 * (td - T[j])) ^ 2)
                    if (e < d) d = e
                }
                if (d > best) { best = d; th = t; z = zz; cx = W / 2 + sx; cy = H / 2 + sy; btx = tx; bty = ty; btd = td }
            }
            TX[i] = btx; TY[i] = bty; Z[i] = z; T[i] = btd; FL[i] = flip
            hw = W / (2 * z); hh = H / (2 * z)
            split("-1 1 -1 1", lxs, " "); split("-1 -1 1 1", lys, " ")
            geo = ""
            for (q = 1; q <= 4; q++) {
                lx = lxs[q] * hw; ly = lys[q] * hh
                px = clamp(cx + lx * cos(th) - ly * sin(th) + (rand() * 2 - 1) * jit, 0, W)
                py = clamp(cy + lx * sin(th) + ly * cos(th) + (rand() * 2 - 1) * jit, 0, H)
                geo = geo sprintf("x%d=%.2f:y%d=%.2f:", q - 1, px, q - 1, py)
            }

            # --- световое поле: сумма трёх плавных волн 1–5 периодов на кадр
            amp = lerp(fa1[k], fa2[k], u("field", i))
            fexpr = "128"
            split("0.5 0.3 0.2", wt, " ")
            for (q = 1; q <= 3; q++) {
                do { fx = rand() * 10 - 5; fy = rand() * 10 - 5 } while (fx * fx + fy * fy < 1)
                fexpr = fexpr sprintf("+%.3f*cos(2*PI*(%.3f*X/W+%.3f*Y/H)+%.3f)", amp * wt[q], fx, fy, rand() * 2 * PI)
            }

            # --- звук
            pitch = 1 + sgn(pi1[k], pi2[k], u("pitch", i))
            osr = u("osr", i) < 0.5 ? 44100 : 48000
            lp = lerp(16500, 19000, u("lp", i)); if (lp > osr * 0.45) lp = osr * 0.45

            printf "V_GEO=\047%s\047 V_ZOOM=%s V_ROT=%s V_FLIP=%d ", substr(geo, 1, length(geo) - 1), r3(z), r3(th * 180 / PI), flip
            printf "V_SPEED=%s V_TS=%s V_TE=%s ", r6(1 + sgn(sp1[k], sp2[k], u("speed", i))), r3(lerp(0.02, ts2[k], u("ts", i))), r3(lerp(0, te2[k], u("te", i)))
            printf "V_BR=%s V_CT=%s V_SA=%s V_GA=%s V_HUE=%s ", r3(sgn(br1[k], br2[k], u("br", i))), r3(1 + sgn(ct1[k], ct2[k], u("ct", i))), r3(1 + sgn(sa1[k], sa2[k], u("sa", i))), r3(1 + sgn(ga1[k], ga2[k], u("ga", i))), r3(sgn(hu1[k], hu2[k], u("hue", i)))
            printf "V_FIELD=\047%s\047 V_GRAIN=%d V_SHARP=%s ", fexpr, int(lerp(gr1[k], gr2[k] + 0.999, u("grain", i))), r3(lerp(-0.2, 0.45, u("sharp", i)))
            printf "V_BRATE=%s V_CRF=%s V_GOP=%s ", r3(lerp(0.88, 1.15, u("vbr", i))), sprintf("%.1f", lerp(17, 19.5, u("crf", i))), r3(lerp(1, 2.5, u("gop", i)))
            printf "A_RATE=%d A_TEMPO_PITCH=%s A_OSR=%d A_VOL=%s ", int(sr * pitch + 0.5), r6(pitch), osr, r3(sgn(0.2, eq2[k], u("vol", i)))
            printf "A_F1=%d A_G1=%s A_F2=%d A_G2=%s ", int(exp(lerp(log(120), log(1000), u("f1", i)))), r3(sgn(0.3, eq2[k], u("g1", i))), int(exp(lerp(log(1200), log(8000), u("f2", i)))), r3(sgn(0.3, eq2[k], u("g2", i)))
            printf "A_HP=%d A_LP=%d A_BR=%d\n", int(lerp(20, 45, u("hp", i))), int(lp), 160 + 32 * int(u("abr", i) * 4)
        }
    }'
}

# ----------------------------------------------------------- одна копия --

# render_variant <вход> <выход.part> <строка параметров>
render_variant() {
    local in="$1" part="$2" vlog="$3" params="$4"
    local V_GEO V_ZOOM V_ROT V_FLIP V_SPEED V_TS V_TE V_BR V_CT V_SA V_GA V_HUE V_FIELD V_GRAIN V_SHARP
    local V_BRATE V_CRF V_GOP A_RATE A_TEMPO_PITCH A_OSR A_VOL A_F1 A_G1 A_F2 A_G2 A_HP A_LP A_BR
    eval "$params"

    local dur="" vf af fc gop vbr enc
    dur=$(awk -v d="$SRC_DUR" -v a="$V_TS" -v b="$V_TE" 'BEGIN { if (d + 0 > 0) { x = d - a - b; if (x < 0.5) x = d - a; if (x > 0) printf "%.3f", x } }')

    # Видео: масштаб -> (HDR->SDR) -> 8 бит -> скорость -> геометрия -> цвет -> поле -> резкость -> зерно.
    vf="[0:v]scale=${OUT_W}:${OUT_H}:flags=lanczos,${HDR_CHAIN}format=yuv420p"
    vf="$vf,setpts=(PTS-STARTPTS)/${V_SPEED},fps=${OUT_FPS}"
    [ "$V_FLIP" = 1 ] && vf="$vf,hflip"
    vf="$vf,perspective=${V_GEO}:interpolation=cubic"
    vf="$vf,eq=brightness=${V_BR}:contrast=${V_CT}:saturation=${V_SA}:gamma=${V_GA},hue=h=${V_HUE}[base];"
    vf="${vf}color=c=gray:s=$(( OUT_W / 15 ))x$(( OUT_H / 15 )):r=1:d=1,format=gray,geq=lum=${V_FIELD},"
    vf="${vf}scale=${OUT_W}:${OUT_H}:flags=bicubic,format=yuv420p[field];"
    # grainmerge (A + B - 128) только для яркости; цвет (c1, c2) в режиме normal берётся из кадра.
    vf="${vf}[base][field]blend=c0_mode=grainmerge"
    vf="$vf,unsharp=5:5:${V_SHARP}:5:5:0"
    [ "$V_GRAIN" -gt 0 ] && vf="$vf,noise=c0s=${V_GRAIN}:c0f=t"
    vf="$vf,setsar=1,format=yuv420p[v]"
    fc="$vf"

    if [ "$SRC_AUDIO" = 1 ]; then
        af="[0:a]asetrate=${A_RATE},aresample=${A_OSR},atempo=$(awk -v s="$V_SPEED" -v p="$A_TEMPO_PITCH" 'BEGIN { printf "%.6f", s / p }')"
        af="$af,highpass=f=${A_HP},lowpass=f=${A_LP}"
        af="$af,equalizer=f=${A_F1}:t=q:w=1:g=${A_G1},equalizer=f=${A_F2}:t=q:w=1:g=${A_G2}"
        af="$af,volume=${A_VOL}dB[a]"
        fc="$fc;$af"
    fi

    gop=$(awk -v f="$OUT_FPS_NUM" -v g="$V_GOP" 'BEGIN { printf "%d", f * g + 0.5 }')
    vbr=$(awk -v b="$BASE_KBPS" -v k="$V_BRATE" 'BEGIN { printf "%d", b * k }')

    local cmd
    cmd=(ffmpeg -hide_banner -nostdin -y -loglevel error -ss "$V_TS")
    [ -n "$dur" ] && cmd+=(-t "$dur")
    cmd+=(-i "$in" -filter_complex "$fc" -map "[v]")
    [ "$SRC_AUDIO" = 1 ] && cmd+=(-map "[a]" -c:a aac -b:a "${A_BR}k")
    cmd+=(-g "$gop" -pix_fmt yuv420p)
    [ -n "$COLOR_ARGS" ] && cmd+=($COLOR_ARGS)
    cmd+=(-map_metadata -1 -map_chapters -1 -fflags +bitexact
          -metadata creation_time="$(date -u +%Y-%m-%dT%H:%M:%S.000000Z)"
          -metadata:s:v:0 handler_name="Core Media Video" -metadata:s:v:0 encoder="H.264"
          -flags:a +bitexact -movflags +faststart)
    [ "$SRC_AUDIO" = 1 ] && cmd+=(-metadata:s:a:0 handler_name="Core Media Audio")

    enc="$ENCODER"
    [ -f "$TMPD/no_videotoolbox" ] && enc=x264
    if [ "$enc" = videotoolbox ]; then
        if "${cmd[@]}" -c:v h264_videotoolbox -b:v "${vbr}k" -profile:v high -allow_sw 1 "$part" 2>"$vlog"; then
            return 0
        fi
        # Аппаратный кодировщик не справился — дальше работаем через x264.
        { echo "videotoolbox failed:"; cat "$vlog"; } >>"$vlog.vt" 2>/dev/null
        : >"$TMPD/no_videotoolbox"
    fi
    # filter_units убирает SEI, в котором x264 подписывает свою версию и настройки.
    "${cmd[@]}" -c:v libx264 -preset medium -crf "$V_CRF" -maxrate "$(( vbr * 3 / 2 ))k" -bufsize "$(( vbr * 3 ))k" \
        -profile:v high -bsf:v filter_units=remove_types=6 "$part" 2>"$vlog"
}

# ------------------------------------------------------------ один файл --

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/unikalizator.XXXXXX") || die "Не удалось создать временную папку."
PIDS=()
PARTS=()

cleanup() {
    local p
    # Копии работают в фоновых подоболочках: останавливаем и их ffmpeg.
    for p in "${PIDS[@]}"; do pkill -TERM -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
    [ ${#PIDS[@]} -gt 0 ] && wait "${PIDS[@]}" 2>/dev/null
    for p in "${PARTS[@]}"; do rm -f "$p"; done
    rm -rf "$TMPD"
    log "STOPPED: остановлено пользователем"
}
trap 'cleanup; exit 130' INT TERM HUP
trap 'rm -rf "$TMPD"' EXIT

# Не даём Mac уснуть, пока идёт работа.
command -v caffeinate >/dev/null && { caffeinate -i -w $$ >/dev/null 2>&1 & }

process_file() {
    local in="$1" dir name base outdir i n params out part started ok=0 fail=0 status outs vlogs
    [ -f "$in" ] || { alert "Файл не найден: $in"; return 1; }

    dir=$(cd "$(dirname "$in")" && pwd) || return 1
    name="${in##*/}"; base="${name%.*}"
    outdir="$dir"
    [ "$SUBFOLDER" = 1 ] && outdir="$dir/${base}_uniq"
    [ -n "$OUTDIR" ] && outdir="$OUTDIR"
    mkdir -p "$outdir" 2>/dev/null
    [ -w "$outdir" ] || { alert "Нет доступа на запись в папку «$outdir»."; return 1; }

    probe "$in" || { alert "Не получилось прочитать видео «$name». Это точно видеофайл?"; return 1; }

    # Итоговый размер: короткая сторона не больше MAX_SIDE, обе стороны чётные.
    OUT_W="$SRC_W"; OUT_H="$SRC_H"
    if [ "$OUT_W" -le "$OUT_H" ] && [ "$OUT_W" -gt "$MAX_SIDE" ]; then
        OUT_H=$(( OUT_H * MAX_SIDE / OUT_W )); OUT_W="$MAX_SIDE"
    elif [ "$OUT_H" -lt "$OUT_W" ] && [ "$OUT_H" -gt "$MAX_SIDE" ]; then
        OUT_W=$(( OUT_W * MAX_SIDE / OUT_H )); OUT_H="$MAX_SIDE"
    fi
    OUT_W=$(( OUT_W / 2 * 2 )); OUT_H=$(( OUT_H / 2 * 2 ))

    OUT_FPS=$(pick_fps "$SRC_FPS" "$SRC_RFPS")
    OUT_FPS_NUM=$(awk -v s="$OUT_FPS" 'BEGIN { p = index(s, "/"); if (p) print substr(s, 1, p - 1) / substr(s, p + 1); else print s + 0 }')
    BASE_KBPS=$(awk -v w="$OUT_W" -v h="$OUT_H" -v f="$OUT_FPS_NUM" 'BEGIN { printf "%d", w * h * f * 0.14 / 1000 }')

    # HDR (iPhone HLG/Dolby Vision, PQ) переводим в обычный SDR — так его покажет Instagram.
    HDR_CHAIN=""
    COLOR_ARGS=""
    case "$SRC_TRC" in
        smpte2084|arib-std-b67)
            if has_filter zscale && has_filter tonemap; then
                HDR_CHAIN="zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,"
            else
                HDR_CHAIN="colorspace=all=bt709:iall=bt2020:itrc=bt2020-10:fast=1,"
            fi
            COLOR_ARGS="-colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv"
            ;;
        *)
            # Обычное видео: переносим цветовые метки исходника, если они осмысленные.
            case "$SRC_SPACE" in bt709|smpte170m|bt470bg|bt2020nc) COLOR_ARGS="$COLOR_ARGS -colorspace $SRC_SPACE" ;; esac
            case "$SRC_PRIM" in bt709|smpte170m|bt470bg|bt2020) COLOR_ARGS="$COLOR_ARGS -color_primaries $SRC_PRIM" ;; esac
            case "$SRC_TRC" in bt709|smpte170m|iec61966-2-1|gamma22|gamma28|bt2020-10) COLOR_ARGS="$COLOR_ARGS -color_trc $SRC_TRC" ;; esac
            ;;
    esac

    local seed="$SEED"
    [ -n "$seed" ] || seed=$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d ' ')
    [ -n "$seed" ] || seed=$(( $(date +%s) + $$ ))

    log "START '$in' ${SRC_W}x${SRC_H} -> ${OUT_W}x${OUT_H}@${OUT_FPS} audio=$SRC_AUDIO trc=${SRC_TRC:-?} count=$COUNT strength=$STRENGTH encoder=$ENCODER jobs=$JOBS seed=$seed"
    say "«$name»: ${OUT_W}x${OUT_H}, $COUNT копий (сила: $STRENGTH, кодировщик: $ENCODER, потоков: $JOBS)"
    notify "Уникализатор" "«$name»: делаю $COUNT копий…"

    started=$(date +%s)
    i=0; n=0
    PIDS=(); PARTS=(); outs=(); vlogs=()
    while IFS= read -r params; do
        i=$(( i + 1 ))
        # Следующий свободный номер: уже существующие копии не перезаписываем.
        while :; do
            n=$(( n + 1 ))
            out="$outdir/${base}${SUFFIX}$(printf '%02d' "$n").mp4"
            part="$outdir/.${base}${SUFFIX}$(printf '%02d' "$n").part.mp4"
            [ -e "$out" ] || [ -e "$part" ] || break
        done
        : >"$part"
        PARTS+=("$part"); outs+=("$out"); vlogs+=("$TMPD/$i.log")

        if [ ${#PIDS[@]} -ge "$JOBS" ]; then
            wait "${PIDS[0]}"; status=$?
            finish_one $status
            PIDS=("${PIDS[@]:1}")
        fi
        log "  #$n $params"
        render_variant "$in" "$part" "$TMPD/$i.log" "$params" </dev/null &
        PIDS+=($!)
    done < <(gen_params "$COUNT" "$seed" "$STRENGTH" "$MIRROR" "$OUT_W" "$OUT_H" "$SRC_SR")

    while [ ${#PIDS[@]} -gt 0 ]; do
        wait "${PIDS[0]}"; status=$?
        finish_one $status
        PIDS=("${PIDS[@]:1}")
    done

    # Всё, что не дошло до готового файла, — ошибка (в том числе если генератор параметров упал).
    fail=$(( COUNT - ok ))
    local took=$(( $(date +%s) - started )) msg
    msg="$ok из $COUNT готово за $(( took / 60 )) мин $(( took % 60 )) с"
    log "DONE '$in' ok=$ok fail=$fail took=${took}s"
    if [ "$fail" -gt 0 ]; then
        say "«$name»: $msg, ошибок: $fail. Подробности: $LOG"
        alert "«$name»: $msg. Не получилось: $fail. Подробности в журнале: $LOG"
        return 1
    fi
    say "«$name»: $msg → $outdir"
    notify "Уникализатор" "«$name»: $msg"
    return 0
}

# Учитывает завершение самой старой из запущенных копий (их порядок = порядок PARTS).
DONE_IDX=0
finish_one() {
    local status="$1" part out vlog
    part="${PARTS[$DONE_IDX]}"; out="${outs[$DONE_IDX]}"; vlog="${vlogs[$DONE_IDX]}"
    DONE_IDX=$(( DONE_IDX + 1 ))
    [ -f "$vlog.vt" ] && { log "videotoolbox fallback for '$out':"; cat "$vlog.vt" >>"$LOG" 2>/dev/null; }
    if [ "$status" -eq 0 ] && [ -s "$part" ] && mv -f "$part" "$out"; then
        ok=$(( ok + 1 ))
        say "  [$(( ok + fail ))/$COUNT] ${out##*/}"
    else
        fail=$(( fail + 1 ))
        rm -f "$part"
        log "FAIL '$out' (exit $status):"
        cat "$vlog" >>"$LOG" 2>/dev/null
        say "  [$(( ok + fail ))/$COUNT] ${out##*/} — ошибка (см. $LOG)"
    fi
}

rc=0
for f in "${FILES[@]}"; do
    DONE_IDX=0
    process_file "$f" || rc=1
done
[ "$rc" = 0 ] && chime
exit $rc
}
