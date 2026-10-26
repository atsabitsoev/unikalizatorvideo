#!/bin/bash
#
# Быстрая проверка уникализатора на синтетических видео (работает на macOS и Linux).
# Проверяет: имена с пробелами и кириллицей, видео без звука, повёрнутое видео
# с телефона, HDR (HLG), 4K -> 1080, повторный запуск без перезаписи, метаданные.
#
# Запуск: bash tests/smoke_test.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNIK="$ROOT/unikalizator.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/unik-test.XXXXXX")
export UNIK_LOG="$WORK/test.log" UNIK_SETTINGS=/nonexistent
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAILS=0
check() { # описание, команда...
    local what="$1"; shift
    if "$@"; then PASS=$(( PASS + 1 )); echo "  ok   $what"
    else FAILS=$(( FAILS + 1 )); echo "  FAIL $what"; fi
}
probe() { ffprobe -v error -select_streams "$2" -show_entries "$3" -of default=nw=1:nk=1 "$1" | head -1; }
gen() { ffmpeg -hide_banner -loglevel error -y "$@"; }

echo "Готовлю тестовые видео в $WORK"
gen -f lavfi -i "testsrc2=s=720x1280:r=30:d=4" -f lavfi -i "sine=f=330:d=4:sample_rate=48000" \
    -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -metadata title="SECRET" "$WORK/Моё видео 1.mp4"
gen -f lavfi -i "testsrc2=s=640x360:r=25:d=3" -c:v libx264 -preset ultrafast -pix_fmt yuv420p "$WORK/noaudio.mp4"
gen -f lavfi -i "testsrc2=s=1280x720:r=30:d=3" -f lavfi -i "sine=f=440:d=3" \
    -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac "$WORK/flat.mp4"
gen -display_rotation 90 -i "$WORK/flat.mp4" -c copy "$WORK/rotated.mp4" 2>/dev/null ||
    gen -i "$WORK/flat.mp4" -c copy -metadata:s:v rotate=90 "$WORK/rotated.mp4"
gen -f lavfi -i "testsrc2=s=2160x3840:r=30:d=2" -c:v libx264 -preset ultrafast -pix_fmt yuv420p "$WORK/uhd.mp4"
gen -f lavfi -i "testsrc2=s=640x360:r=30:d=2" -c:v libx264 -preset ultrafast -pix_fmt yuv420p10le \
    -color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc "$WORK/hlg.mp4"

echo "1. Обычное видео с кириллицей и пробелом в имени"
"$UNIK" -n 3 --seed 1 "$WORK/Моё видео 1.mp4" >/dev/null
for i in 01 02 03; do
    f="$WORK/Моё видео 1_uniq_$i.mp4"
    check "копия $i создана" test -s "$f"
    check "копия $i декодируется без ошибок" test -z "$(ffmpeg -v error -i "$f" -f null - 2>&1)"
done
f="$WORK/Моё видео 1_uniq_01.mp4"
check "размер кадра сохранён (720x1280)" test "$(probe "$f" v:0 stream=width)x$(probe "$f" v:0 stream=height)" = 720x1280
check "есть звук" test -n "$(probe "$f" a:0 stream=codec_name)"
sat() { ffmpeg -v error -i "$1" -vf signalstats,metadata=print:key=lavfi.signalstats.SATAVG:file=- -f null - |
    awk -F= '/SATAVG/ { s += $2; n++ } END { if (n) printf "%d", s / n }'; }
so=$(sat "$WORK/Моё видео 1.mp4"); sv=$(sat "$f")
check "цвет сохранён (насыщенность $sv против $so у исходника)" test "$sv" -gt $(( so * 85 / 100 )) -a "$sv" -lt $(( so * 115 / 100 ))
check "метаданные исходника удалены" test -z "$(ffprobe -v error -show_entries format_tags=title -of default=nw=1:nk=1 "$f")"
check "нет подписи ffmpeg/x264 внутри файла" test -z "$(LC_ALL=C grep -aoE 'Lavf|Lavc|x264 - core' "$f" | head -1)"
check "копии отличаются от исходника по длительности" \
    test "$(probe "$f" v:0 format=duration)" != "$(probe "$WORK/Моё видео 1.mp4" v:0 format=duration)"
check "копии не совпадают побайтно" test "$(cksum <"$WORK/Моё видео 1_uniq_01.mp4")" != "$(cksum <"$WORK/Моё видео 1_uniq_02.mp4")"
check "не осталось временных .part-файлов" test -z "$(ls -A "$WORK" | grep '\.part\.mp4$')"

echo "2. Повторный запуск не перезаписывает старые копии"
"$UNIK" -n 2 --seed 2 "$WORK/Моё видео 1.mp4" >/dev/null
check "появились _04 и _05" test -s "$WORK/Моё видео 1_uniq_04.mp4" -a -s "$WORK/Моё видео 1_uniq_05.mp4"

echo "3. Видео без звука"
"$UNIK" -n 1 "$WORK/noaudio.mp4" >/dev/null
check "создано" test -s "$WORK/noaudio_uniq_01.mp4"
check "звуковой дорожки нет" test -z "$(probe "$WORK/noaudio_uniq_01.mp4" a:0 stream=codec_name)"

echo "4. Повёрнутое видео (как с телефона)"
"$UNIK" -n 1 "$WORK/rotated.mp4" >/dev/null
f="$WORK/rotated_uniq_01.mp4"
check "кадр вертикальный 720x1280" test "$(probe "$f" v:0 stream=width)x$(probe "$f" v:0 stream=height)" = 720x1280

echo "5. 4K уменьшается до 1080 по короткой стороне"
"$UNIK" -n 1 "$WORK/uhd.mp4" >/dev/null
f="$WORK/uhd_uniq_01.mp4"
check "1080x1920" test "$(probe "$f" v:0 stream=width)x$(probe "$f" v:0 stream=height)" = 1080x1920

echo "6. HDR (HLG) переводится в SDR"
"$UNIK" -n 1 "$WORK/hlg.mp4" >/dev/null
f="$WORK/hlg_uniq_01.mp4"
check "создано" test -s "$f"
check "8 бит, bt709" test "$(probe "$f" v:0 stream=pix_fmt)/$(probe "$f" v:0 stream=color_transfer)" = yuv420p/bt709

echo "7. Сила light/strong, отдельная папка, зеркало"
"$UNIK" -n 2 -s light -o "$WORK/out light" "$WORK/flat.mp4" >/dev/null
check "light → папка -o" test -s "$WORK/out light/flat_uniq_02.mp4"
"$UNIK" -n 2 -s strong --mirror -o "$WORK/out strong" "$WORK/flat.mp4" >/dev/null
check "strong + mirror" test -s "$WORK/out strong/flat_uniq_02.mp4"

echo "8. Ошибки"
check "несуществующий файл → код ошибки" bash -c '! "$0" -n 1 /nonexistent.mp4 2>/dev/null' "$UNIK"
check "не видео → код ошибки" bash -c 'echo hi > "$1/x.mp4"; ! "$0" -n 1 "$1/x.mp4" 2>/dev/null' "$UNIK" "$WORK"
check "неверная сила → код ошибки" bash -c '! "$0" -s ultra "$1" 2>/dev/null' "$UNIK" "$WORK/flat.mp4"

echo
echo "Пройдено: $PASS, не пройдено: $FAILS"
[ "$FAILS" = 0 ] || { cp "$WORK/test.log" "${TMPDIR:-/tmp}/unik-test-last.log" 2>/dev/null && echo "Журнал: ${TMPDIR:-/tmp}/unik-test-last.log"; }
[ "$FAILS" = 0 ]
