# IP Manager

`ip-manager` — интерактивная Bash-утилита для безопасного управления дополнительными IPv4 на Ubuntu и Debian. Она определяет интерфейс по IPv4 default route, не хардкодит имя NIC и хранит собственный state отдельно от конфигурации провайдера.

> **Важно:** утилита настраивает Linux. Она не назначает IP серверу в панели/API хостинг-провайдера и не создаёт маршрутизацию на стороне провайдера.

## Приоритет безопасности

Обычные операции add/delete **не перезапускают всю сеть**. Сначала IP Manager строит и проверяет persistent-конфигурацию, затем точечно выполняет `ip address add/del` на уже работающем интерфейсе. Default gateway, основной IPv4, DNS, MTU, bond, VLAN и маршруты утилита не меняет.

Если backend или владелец конфигурации нельзя определить однозначно, программа завершает работу без изменений.

## Поддержка v1

- Ubuntu, Debian.
- Netplan: managed overlay `/etc/netplan/90-ip-manager.yaml`; тип и Netplan ID интерфейса определяются из объединённой модели `netplan get`.
- NetworkManager: используется активный connection UUID; изменяется только `ipv4.addresses`.
- native systemd-networkd: drop-in для реально применённого `.network` файла.
- ifupdown: только если `/etc/network/interfaces.d` уже подключён; основной `/etc/network/interfaces` не редактируется.

### Осознанные ограничения

1. **Импорт чужих persistent IP в v1 автоматизирован не полностью.** Это намеренно. В Netplan sequence `addresses` из нескольких YAML объединяются, поэтому overlay-файл не может безопасно «вычесть» адрес из provider YAML. Аналогично ownership может быть неоднозначным в NM/networkd/ifupdown. Меню импорта показывает кандидатов и объясняет безопасную процедуру, но не удаляет чужую конфигурацию.
2. Primary IPv4 определяется как `src`, выбранный ядром для маршрута через default interface. Если это нельзя определить однозначно, программа останавливается.
3. Policy routing может означать, что одного default route недостаточно для описания всей топологии. IP Manager не создаёт `ip rule`/дополнительные routing tables. Если source-based routing требует их у вашего провайдера, настройте их отдельно.
4. `/32` — допустимый secondary/routed IPv4 и не требует отдельного gateway сам по себе, если провайдер уже маршрутизирует адрес на сервер и существующая таблица маршрутизации позволяет исходящий трафик. Это не универсальная гарантия для любой сети.
5. Wi-Fi, tunnels и экзотические Netplan-конфигурации могут быть распознаны, но v1 рассчитан прежде всего на серверные Ethernet/bond/VLAN/bridge схемы. Неоднозначность приводит к fail-safe отказу.

## Установка

### Быстрая установка с GitHub

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Khalif-abd/ip-manager/main/install.sh)
```

После установки:

```bash
sudo ip-manager
```

### Установка через Git

```bash
git clone https://github.com/Khalif-abd/ip-manager.git
cd ip-manager
sudo ./install.sh
```

Файлы:

* `/usr/local/sbin/ip-manager` — программа;
* `/var/lib/ip-manager/managed.tsv` — минимальный state;
* `/var/log/ip-manager.log` — журнал операций.

## Обновление

Из меню `sudo ip-manager` выберите `7) Обновить IP Manager`, либо выполните:

```bash
sudo ip-manager update
```

Обновление скачивает `ip-manager.sh` из ветки `main`, проверяет его через `bash -n` и только после успешной проверки атомарно заменяет `/usr/local/sbin/ip-manager`. State и сетевые managed-файлы не удаляются.

Проверить версию:

```bash
ip-manager version
```

## Использование

Меню:

```text
1) Добавить IP
2) Удалить IP
3) Показать IP
4) Проверить IP
5) Импортировать существующие IP
6) Диагностика
0) Выход
```

### Массовое добавление

```text
195.189.98.135 195.189.98.136/32 203.0.113.20/28
```

Без prefix используется `/32`. Перед изменением программа валидирует IPv4/CIDR, дубликаты, наличие адреса на интерфейсе и защиту primary IP, затем показывает единое подтверждение.

### Массовое удаление

Удалять можно только адреса `[IP Manager]`. Выбор выполняется номерами, например:

```text
2 4 5
```

Системные IP и primary IP через это меню недоступны для удаления.

## Проверка

Для каждого адреса различаются три состояния:

- адрес присутствует в runtime;
- адрес находится под persistent-управлением IP Manager;
- `curl --interface IP -4 https://api.ipify.org` способен выполнить исходящее соединение.

Если IP назначен локально, но внешний тест не проходит, это не доказывает ошибку Linux-конфигурации: адрес может не быть назначен/маршрутизирован провайдером.

## Netplan и несколько YAML

Netplan читает YAML из нескольких каталогов и объединяет файлы в лексикографическом порядке. Mapping дополняются/переопределяются, а sequence (включая `addresses`) объединяются. Поэтому IP Manager может безопасно **добавлять** свои addresses отдельным YAML, но не может универсально удалить адрес, который остаётся объявленным в чужом YAML. Именно поэтому автоматическая миграция provider-файлов не выполняется.

IP Manager запускает `netplan generate` после атомарной записи managed YAML. Для обычного add/delete он не вызывает `netplan apply`: runtime IP меняется точечно через `ip`.

## systemd-networkd

Для native networkd программа получает реально применённый `.network` через `networkctl status` и создаёт drop-in `<file>.d/90-ip-manager.conf` с дополнительными `Address=`. Если обнаружен generated Netplan networkd-файл при невозможности определить Netplan source, программа отказывается от изменений.

## NetworkManager

IP Manager работает с UUID активного connection profile и использует additive/subtractive изменение `ipv4.addresses`. Он не меняет gateway, DNS, method, MTU или маршруты и не делает `connection down/up`.

## ifupdown

Поддерживается только существующая схема, где `/etc/network/interfaces.d` уже подключён через `source`/`source-directory`. IP Manager не добавляет include в основной файл автоматически. Managed-файл использует точечные `ip address add/del` hooks.

## Работа по SSH и rollback

Никакой rollback не способен гарантированно спасти удалённый сервер при любой ошибке: если connectivity потеряна и механизм отката зависит от текущей SSH-сессии, это не rollback. Даже `netplan try` имеет документированные оговорки по фактическому восстановлению.

Поэтому v1 избегает network-wide apply/restart. Перед первым использованием на новом типе инфраструктуры всё равно рекомендуется иметь out-of-band console/IPMI/VNC/serial console от провайдера.

Если persistent validation не проходит, runtime не меняется. Если persistent запись прошла, но точечный runtime `ip address add` неожиданно падает, уже добавленные в рамках операции runtime IP откатываются; программа явно сообщает, что persistent state следует удалить через меню до reboot.

## Диагностика

Пункт `Диагностика` выводит ОС, backend, default interface, primary IPv4, gateway, `ip -4 addr`, `ip -4 route`, managed/system IP и состояние сетевых служб. Для Netplan также выводится `netplan get`.

Перед публикацией диагностики проверьте её содержимое: сетевые адреса не считаются секретами самой утилитой.

## Удаление программы

Из меню `sudo ip-manager` выберите `8) Удалить IP Manager`, либо:

```bash
sudo ip-manager uninstall
```

Удаление **не снимает IP и не удаляет persistent managed-конфигурацию автоматически**. Если managed IP ещё существуют, программа покажет их и отдельно предупредит об этом. Ненужные IP следует сначала удалить через основное меню. Такой подход предотвращает неожиданное исчезновение production IP после uninstall или reboot.

Standalone `uninstall.sh` оставлен для совместимости и делегирует удаление установленному `ip-manager`.

## Модель state

`managed.tsv` содержит пары `interface<TAB>CIDR`. State — маркер ownership, но не единственный источник истины: runtime всегда сверяется через `ip addr`, а backend-конфигурация валидируется отдельно.

## Лицензия

MIT.
