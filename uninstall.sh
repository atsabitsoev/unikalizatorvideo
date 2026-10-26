#!/bin/bash
#
# Удаление «Уникализатора»: пункт меню Finder, скрипт, настройки и скачанный ffmpeg.
# Сами видео (исходники и сделанные копии) не трогаются.
#
# Запуск: bash uninstall.sh

APP_DIR="$HOME/Library/Application Support/Unikalizator"
SERVICE="$HOME/Library/Services/Уникализировать.workflow"

rm -rf "$SERVICE" && echo "✓ удалён пункт меню «Уникализировать»"
rm -rf "$APP_DIR" && echo "✓ удалена папка $APP_DIR"
rm -f "$HOME/Library/Logs/Unikalizator.log"
/System/Library/CoreServices/pbs -flush >/dev/null 2>&1
/System/Library/CoreServices/pbs -update >/dev/null 2>&1
echo "Готово. ffmpeg, установленный через Homebrew (если был), остался на месте."
