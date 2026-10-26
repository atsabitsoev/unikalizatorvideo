#!/bin/bash
# Двойной клик — удаление уникализатора.
cd "$(dirname "$0")" && bash ./uninstall.sh
echo
read -n 1 -s -r -p "Нажмите любую клавишу, чтобы закрыть окно…"
