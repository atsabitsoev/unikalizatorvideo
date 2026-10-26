#!/bin/bash
#
# Установка «Уникализатора»:
#   1. копирует скрипт в ~/Library/Application Support/Unikalizator;
#   2. ставит ffmpeg, если его нет (статическая сборка, без Homebrew и пароля);
#   3. добавляет в контекстное меню Finder пункт «Уникализировать».
#
# Запуск: bash install.sh

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$HOME/Library/Application Support/Unikalizator"
SERVICE_DIR="$HOME/Library/Services"
SERVICE="$SERVICE_DIR/Уникализировать.workflow"
FFMPEG_BASE="https://ffmpeg.martin-riedl.de/redirect/latest/macos"

REQUIRED_FILTERS="perspective eq hue geq blend unsharp noise fps setpts asetrate atempo aresample equalizer"

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '    ✓ %s\n' "$*"; }
fail() { printf '\n\033[31mОшибка: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(uname)" = Darwin ] || fail "Уникализатор работает только на macOS."
for f in unikalizator.sh settings.conf workflow/Unikalizator.workflow/Contents/document.wflow; do
    [ -e "$SRC_DIR/$f" ] || fail "Не найден файл $f — запускайте install.sh из папки уникализатора."
done

# Подходит ли ffmpeg: есть ffprobe и все нужные фильтры.
ffmpeg_ok() { # путь_к_ffmpeg
    local ff="$1" probe filters f
    probe="$(dirname "$ff")/ffprobe"
    [ -x "$ff" ] && [ -x "$probe" ] || return 1
    filters=$("$ff" -hide_banner -filters 2>/dev/null) || return 1
    for f in $REQUIRED_FILTERS; do
        printf '%s\n' "$filters" | grep -qE "^ *[^ =]+ +$f +" || return 1
    done
    "$ff" -hide_banner -encoders 2>/dev/null | grep -qE "^ *[^ =]+ +(h264_videotoolbox|libx264) +"
}

download_ffmpeg() {
    local arch tool tmp
    case "$(uname -m)" in
        arm64) arch=arm64 ;;
        *)     arch=amd64 ;;
    esac
    tmp=$(mktemp -d) || return 1
    for tool in ffmpeg ffprobe; do
        echo "    скачиваю $tool ($arch)…"
        curl -fL --progress-bar --retry 3 -o "$tmp/$tool.zip" "$FFMPEG_BASE/$arch/release/$tool.zip" || { rm -rf "$tmp"; return 1; }
        unzip -o -q "$tmp/$tool.zip" -d "$tmp/$tool" || { rm -rf "$tmp"; return 1; }
        [ -f "$tmp/$tool/$tool" ] || { rm -rf "$tmp"; return 1; }
        mv -f "$tmp/$tool/$tool" "$APP_DIR/bin/$tool"
        chmod +x "$APP_DIR/bin/$tool"
        xattr -d com.apple.quarantine "$APP_DIR/bin/$tool" 2>/dev/null
        # На Apple Silicon неподписанный бинарник не запустится — подписываем локально.
        "$APP_DIR/bin/$tool" -version >/dev/null 2>&1 || codesign --force --sign - "$APP_DIR/bin/$tool" >/dev/null 2>&1
    done
    rm -rf "$tmp"
}

# --------------------------------------------------------------------------

step "Копирую файлы в «$APP_DIR»"
mkdir -p "$APP_DIR/bin" || fail "Не удалось создать папку $APP_DIR"
# Через временный файл и mv: если уникализатор сейчас работает, он доработает старой версией.
cp -f "$SRC_DIR/unikalizator.sh" "$APP_DIR/.unikalizator.sh.new" && chmod +x "$APP_DIR/.unikalizator.sh.new" &&
    mv -f "$APP_DIR/.unikalizator.sh.new" "$APP_DIR/unikalizator.sh" || fail "Не удалось скопировать unikalizator.sh"
if [ -f "$APP_DIR/settings.conf" ]; then
    ok "settings.conf уже есть — ваши настройки не трогаю"
else
    cp "$SRC_DIR/settings.conf" "$APP_DIR/settings.conf"
fi
ok "готово"

step "Проверяю ffmpeg"
FF=""
for cand in "$APP_DIR/bin/ffmpeg" /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg "$(command -v ffmpeg 2>/dev/null)"; do
    [ -n "$cand" ] && ffmpeg_ok "$cand" && { FF="$cand"; break; }
done
if [ -z "$FF" ]; then
    echo "    подходящего ffmpeg нет — ставлю свой (около 80 МБ, только в папку уникализатора)"
    if download_ffmpeg && ffmpeg_ok "$APP_DIR/bin/ffmpeg"; then
        FF="$APP_DIR/bin/ffmpeg"
    elif command -v brew >/dev/null 2>&1; then
        echo "    скачать не получилось — пробую через Homebrew"
        brew install ffmpeg && for cand in /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg; do
            ffmpeg_ok "$cand" && { FF="$cand"; break; }
        done
    fi
fi
[ -n "$FF" ] || fail "Не удалось установить ffmpeg. Установите его вручную (https://brew.sh, затем «brew install ffmpeg») и запустите install.sh ещё раз."
# Скрипт запускается из Finder с урезанным PATH и ищет ffmpeg в своей папке,
# в /opt/homebrew/bin и /usr/local/bin. Если ffmpeg нашёлся где-то ещё — даём ссылку.
case "$(dirname "$FF")" in
    "$APP_DIR/bin"|/opt/homebrew/bin|/usr/local/bin) ;;
    *) ln -sf "$FF" "$APP_DIR/bin/ffmpeg"; ln -sf "$(dirname "$FF")/ffprobe" "$APP_DIR/bin/ffprobe" ;;
esac
ok "$("$FF" -version | head -1 | cut -c1-60) — $FF"
if "$FF" -hide_banner -encoders 2>/dev/null | grep -q h264_videotoolbox; then
    ok "аппаратное кодирование VideoToolbox доступно"
fi

step "Добавляю пункт «Уникализировать» в меню Finder"
mkdir -p "$SERVICE_DIR"
rm -rf "$SERVICE"
cp -R "$SRC_DIR/workflow/Unikalizator.workflow" "$SERVICE" || fail "Не удалось скопировать быстрое действие в $SERVICE_DIR"
xattr -dr com.apple.quarantine "$APP_DIR" "$SERVICE" 2>/dev/null
# Обновляем кэш служб, чтобы пункт появился сразу.
/System/Library/CoreServices/pbs -flush >/dev/null 2>&1
/System/Library/CoreServices/pbs -update >/dev/null 2>&1
ok "$SERVICE"

cat <<EOF

$(printf '\033[1;32m')Готово!$(printf '\033[0m')

Как пользоваться:
  Правый клик по видео (.mp4 или .mov) в Finder → «Быстрые действия» → «Уникализировать».
  Рядом с видео появятся 20 файлов вида «имя_uniq_01.mp4» … «имя_uniq_20.mp4».
  Пока идёт работа, в строке меню крутится шестерёнка; по окончании придёт уведомление.

Если пункта нет в меню:
  Системные настройки → Конфиденциальность и безопасность → Расширения →
  Finder (или «Добавленные расширения») → включите «Уникализировать».

При первом запуске macOS может спросить доступ к папке (Загрузки, Рабочий стол…) — разрешите.

Настройки (количество копий, сила изменений, зеркалирование):
  open "$APP_DIR/settings.conf"
Журнал работы:
  ~/Library/Logs/Unikalizator.log
EOF
