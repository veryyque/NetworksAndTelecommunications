#!/bin/bash
# Запуск: ./limit.sh. Остановка и восстановление настроек: Ctrl+C.
set -e
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
[ "$(id -u)" -eq 0 ] || exec sudo /bin/bash "$0"

PORT=6767
RATE=100Mbit/s
PIPE=46767
ANCHOR=com.apple/tcp-lab

# Не допускаем два ограничителя одновременно.
LOCK=/var/run/tcp-lab-simple.lock
mkdir "$LOCK" 2>/dev/null || { echo "Ограничитель уже запущен или остался $LOCK после аварии."; exit 1; }
TOKEN=""; RESTORE_SKIP=0; RULES=0; CHANNEL=0

cleanup() {
    trap - EXIT
    set +e
    failed=0
    if [ "$RESTORE_SKIP" -eq 1 ]; then "$LOCK/helper" restore || failed=1; fi
    if [ "$RULES" -eq 1 ]; then pfctl -a "$ANCHOR" -f /dev/null || failed=1; fi
    if [ "$CHANNEL" -eq 1 ]; then dnctl pipe delete "$PIPE" || failed=1; fi
    if [ -n "$TOKEN" ]; then pfctl -X "$TOKEN" || failed=1; fi
    if [ "$failed" -eq 0 ]; then
        rm -f "$LOCK/helper"
        rmdir "$LOCK"
        echo "Ограничитель остановлен; изменённые настройки восстановлены."
    else
        echo "Не всё удалось восстановить. Сохрани вывод ошибок; файлы оставлены в $LOCK."
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Проверяем, что наша группа правил будет обрабатываться.
anchors=$(pfctl -s dummynet)
printf '%s\n' "$anchors" | grep -Fq 'dummynet-anchor "com.apple/*"' || {
    echo 'Нет точки подключения com.apple/*. Настройка остановлена.'; exit 1;
}
interfaces=$(pfctl -v -s Interfaces -i lo0)

# Небольшой помощник снимает/возвращает только skip у lo0.
# Нужен на этом Mac: без него PF пропускает локальные передачи.
xcrun clang -Wall -Wextra -Werror -x c -o "$LOCK/helper" - <<'C_SOURCE'
// Darwin PF interface ABI: apple-oss-distributions/xnu, bsd/net/pfvar.h.
// Only changes PFI_IFLAG_SKIP on lo0; no rules or other flags are modified.
#include <sys/types.h>
#include <sys/ioctl.h>
#include <net/if.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <stddef.h>
struct lab_pfioc_iface {
    char name[IFNAMSIZ];
    void *buffer __attribute__((aligned(8)));
    int esize __attribute__((aligned(8)));
    int size;
    int nzero;
    int flags;
};
_Static_assert(sizeof(struct lab_pfioc_iface) == 40, "Unsupported PF ABI");
_Static_assert(offsetof(struct lab_pfioc_iface, flags) == 36, "Unsupported PF ABI");
int main(int argc, char **argv) {
    if (argc != 2 || (strcmp(argv[1], "clear") && strcmp(argv[1], "restore"))) {
        fprintf(stderr, "Usage: pf-lo0-skip clear|restore\n"); return 2;
    }
    struct lab_pfioc_iface request = {0};
    strcpy(request.name, "lo0");
    request.flags = 0x0100;
    int fd = open("/dev/pf", O_RDWR);
    if (fd < 0) { perror("open /dev/pf"); return 1; }
    unsigned long op = !strcmp(argv[1], "clear")
        ? _IOWR('D', 90, struct lab_pfioc_iface)
        : _IOWR('D', 89, struct lab_pfioc_iface);
    int result = ioctl(fd, op, &request);
    if (result < 0) perror("change lo0 skip flag");
    close(fd);
    return result < 0 ? 1 : 0;
}
C_SOURCE

# Включаем PF и сохраняем токен именно нашего включения.
result=$(pfctl -E 2>&1)
TOKEN=$(printf '%s\n' "$result" | awk '/Token[[:space:]]*:/ {print $NF}')
[[ "$TOKEN" =~ ^[0-9]+$ ]] || { printf '%s\n' "$result"; exit 1; }

# Общая скорость для всех клиентов, подходящих под правила ниже.
CHANNEL=1
dnctl pipe "$PIPE" config bw "$RATE"
RULES=1
printf '%s\n'     "dummynet out quick on lo0 inet proto tcp from 127.0.0.1 to 127.0.0.1 port $PORT pipe $PIPE"     "dummynet out quick on lo0 inet6 proto tcp from ::1 to ::1 port $PORT pipe $PIPE"     | pfctl -a "$ANCHOR" -f -

if printf '%s\n' "$interfaces" | grep -qi skip; then
    RESTORE_SKIP=1
    "$LOCK/helper" clear
fi
interfaces=$(pfctl -v -s Interfaces -i lo0)
if printf '%s\n' "$interfaces" | grep -qi skip; then
    echo 'Не удалось снять skip с lo0.'; exit 1;
fi

echo "Лимит $RATE суммарно на localhost:$PORT. Для отключения — Ctrl+C."
while true; do sleep 1; done
