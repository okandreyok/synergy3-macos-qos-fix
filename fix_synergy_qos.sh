#!/bin/bash
set -e

PLIST="$HOME/Library/LaunchAgents/com.symless.synergy3.plist"
BACKUP="$PLIST.bak"
UID_NUM=$(id -u)

if [ ! -f "$PLIST" ]; then
  echo "Не знайдено $PLIST — перевір шлях."
  exit 1
fi

echo "===================================================="
echo "1) Знімок QoS ДО змін (якщо synergy-core вже працює)"
echo "===================================================="
EXISTING_PID=$(ps -axo pid,comm | grep -i '[s]ynergy-core' | awk '{print $1}' | head -n1)
if [ -n "$EXISTING_PID" ]; then
  echo "Поточний synergy-core PID: $EXISTING_PID"
  sudo powermetrics --show-process-qos --samplers tasks -i 1000 -n 1 2>/dev/null | grep -i synergy-core || true
else
  echo "synergy-core зараз не запущений."
fi

echo ""
echo "===================================================="
echo "2) Резервна копія plist -> $BACKUP"
echo "===================================================="
if [ ! -f "$BACKUP" ]; then
  cp "$PLIST" "$BACKUP"
  echo "Бекап створено."
else
  echo "Бекап вже існує, не перезаписую."
fi

echo ""
echo "===================================================="
echo "3) Застосовуємо ProcessType = Interactive"
echo "===================================================="
if /usr/libexec/PlistBuddy -c "Print :ProcessType" "$PLIST" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c "Set :ProcessType Interactive" "$PLIST"
  echo "Оновлено існуючий ключ ProcessType -> Interactive."
else
  /usr/libexec/PlistBuddy -c "Add :ProcessType string Interactive" "$PLIST"
  echo "Додано новий ключ ProcessType -> Interactive."
fi

echo ""
echo "===================================================="
echo "4) Повне вбивство всіх процесів Synergy (включно з осиротілими)"
echo "===================================================="
# Спершу коректно через launchctl (сучасний API, не застарілий load/unload)
launchctl bootout "gui/$UID_NUM/com.symless.synergy3" 2>/dev/null || true
sleep 1

# Потім вбиваємо все, що лишилось, за іменем процесу — покриває осиротілі PID
for name in synergy-core synergy-service synergy-tray Synergy; do
  pids=$(ps -axo pid,comm | grep -i -- "$name" | grep -v grep | awk '{print $1}')
  if [ -n "$pids" ]; then
    echo "Вбиваю $name: $pids"
    echo "$pids" | xargs kill -9 2>/dev/null || true
  fi
done
sleep 2

echo ""
echo "===================================================="
echo "5) Чистий старт через сучасний launchctl bootstrap"
echo "===================================================="
launchctl bootstrap "gui/$UID_NUM" "$PLIST" 2>/dev/null || {
  echo "bootstrap не спрацював (можливо вже завантажено), пробую kickstart..."
  launchctl kickstart -k "gui/$UID_NUM/com.symless.synergy3" 2>/dev/null || {
    echo "kickstart теж не спрацював, відкат на legacy load..."
    launchctl load "$PLIST"
  }
}
sleep 3

echo ""
echo "===================================================="
echo "6) Перевірка процесів після рестарту"
echo "===================================================="
ps -axo pid,ppid,comm | grep -i '[s]ynergy'

NEW_PID=$(ps -axo pid,comm | grep -i '[s]ynergy-core' | awk '{print $1}' | head -n1)
if [ -z "$NEW_PID" ]; then
  echo ""
  echo "synergy-core не запустився. Перевір лог:"
  echo "  $HOME/Library/Logs/Synergy/com.symless.synergy3.log"
  echo "  $HOME/Library/Logs/Synergy/com.symless.synergy3_error.log"
  exit 1
fi
echo ""
echo "Новий synergy-core PID: $NEW_PID"

echo ""
echo "===================================================="
echo "7) Дай процесу попрацювати"
echo "===================================================="
echo "Поворуш мишкою між Mac і Windows зараз."
echo "Натисни Enter, коли будеш готовий зняти фінальний QoS-знімок..."
read -r _

echo ""
echo "===================================================="
echo "8) Знімок QoS ПІСЛЯ змін"
echo "===================================================="
sudo powermetrics --show-process-qos --samplers tasks -i 1000 -n 1 | grep -i synergy-core

echo ""
echo "===================================================="
echo "Готово."
echo "Якщо в колонці Util і надалі ненульове значення, а Default/U-Init/U-Intr нулі —"
echo "ProcessType не спрацював (synergy-core форсує QoS сам у коді)."
echo ""
echo "Відкат: cp \"$BACKUP\" \"$PLIST\" && launchctl bootout \"gui/$UID_NUM/com.symless.synergy3\" && launchctl bootstrap \"gui/$UID_NUM\" \"$PLIST\""
echo "===================================================="
