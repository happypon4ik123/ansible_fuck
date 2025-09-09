#!/bin/bash

# Конфигурационные переменные
EVE_NG_HOST="root@eve-ng.lan"
EVE_NG_PASSWORD="xy5KATWWLF"
LAB_FILE="/opt/unetlab/labs/lab1.unl"
ROUTER_HOST="admin@172.16.0.1"
ROUTER_PASSWORD="Test123"
INVENTORY_FILE="/an_pr/playbooks/inv.ini"
GIT_DIR="/an_pr/playbooks"

# Функция для выполнения SSH с паролем
ssh_with_password() {
    local host=$1
    local password=$2
    local command=$3
    
    sshpass -p "$password" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$host" "$command"
}

# Получаем текущие хосты из EVE-NG
get_current_hosts() {
    ssh_with_password "$EVE_NG_HOST" "$EVE_NG_PASSWORD" "cat '$LAB_FILE'" | \
    grep 'image="linux-ubuntu-24.04.01-server"' | \
    while read line; do
        echo "$line" | grep -o 'name="[^"]*"\|firstmac="[^"]*"' | \
        cut -d'"' -f2 | xargs -n2 echo
    done | \
    xargs -n2 -I {} sh -c '
        name=$(echo {} | cut -d" " -f1)
        mac=$(echo {} | cut -d" " -f2)
        ip=$(sshpass -p "'"$ROUTER_PASSWORD"'" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "'"$ROUTER_HOST"'" "/ip dhcp-server lease print where mac-address=$mac" | \
            grep -Eo "([0-9]{1,3}\.){3}[0-9]{1,3}" | head -1)
        echo "$name ansible_host=$ip"
    '
}

# Парсим существующий инвентарь
parse_existing_inventory() {
    local file="$1"
    if [ ! -f "$file" ]; then
        return
    fi

    local current_section=""
    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        if [[ "$line" =~ ^\[.*\]$ ]]; then
            current_section="${line:1:-1}"
        elif [[ -n "$line" && ! "$line" =~ ^# ]]; then
            if [ "$current_section" = "myhosts" ] || [ "$current_section" = "new" ]; then
                echo "$current_section:$line"
            fi
        fi
    done < "$file"
}

# Основная логика
main() {
    echo "=== ОБНОВЛЕНИЕ ИНВЕНТАРЯ ==="

    # Получаем текущие хосты
    echo "Получение текущих хостов из EVE-NG..."
    CURRENT_HOSTS=$(get_current_hosts)
    if [ -z "$CURRENT_HOSTS" ]; then
        echo "Ошибка: не удалось получить хосты из EVE-NG"
        exit 1
    fi

    # Парсим существующий инвентарь
    echo "Анализ существующего инвентаря..."
    declare -A EXISTING_HOSTS
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            section=$(echo "$line" | cut -d: -f1)
            host_line=$(echo "$line" | cut -d: -f2-)
            host_name=$(echo "$host_line" | awk '{print $1}')
            EXISTING_HOSTS["$host_name"]="$section:$host_line"
        fi
    done < <(parse_existing_inventory "$INVENTORY_FILE")

    # Создаем новые секции
    MYHOSTS_SECTION="[myhosts]"
    NEW_SECTION="[new]"
    MYHOSTS_CONTENT=""
    NEW_CONTENT=""

    # Обрабатываем каждый текущий хост
    echo "Обработка хостов..."
    while IFS= read -r host_line; do
        if [ -n "$host_line" ]; then
            host_name=$(echo "$host_line" | awk '{print $1}')

            if [[ -n "${EXISTING_HOSTS[$host_name]}" ]]; then
                # Хост уже существует, проверяем в какой секции
                existing_section=$(echo "${EXISTING_HOSTS[$host_name]}" | cut -d: -f1)
                existing_line=$(echo "${EXISTING_HOSTS[$host_name]}" | cut -d: -f2-)

                if [ "$existing_section" = "myhosts" ]; then
                    MYHOSTS_CONTENT+="$existing_line"$'\n'
                else
                    NEW_CONTENT+="$existing_line"$'\n'
                fi
                # Удаляем из массива обработанных хостов
                unset EXISTING_HOSTS["$host_name"]
            else
                # Новый хост - добавляем в секцию [new]
                NEW_CONTENT+="$host_line"$'\n'
                echo "Добавлен новый хост: $host_name -> [new]"
            fi
        fi
    done <<< "$CURRENT_HOSTS"

    # Проверяем оставшиеся хосты в EXISTING_HOSTS - это лишние хосты
    if [ ${#EXISTING_HOSTS[@]} -gt 0 ]; then
        echo "Обнаружены лишние хосты для удаления:"
        for host_name in "${!EXISTING_HOSTS[@]}"; do
            section=$(echo "${EXISTING_HOSTS[$host_name]}" | cut -d: -f1)
            echo "  Удаляем: $host_name (из секции [$section])"
        done
    fi

    # Собираем полный инвентарь
    FULL_CONTENT="$MYHOSTS_SECTION"$'\n'
    if [ -n "$MYHOSTS_CONTENT" ]; then
        FULL_CONTENT+="$MYHOSTS_CONTENT"$'\n'
    else
        FULL_CONTENT+="# Нет хостов в myhosts"$'\n'$'\n'
    fi

    FULL_CONTENT+="$NEW_SECTION"$'\n'
    if [ -n "$NEW_CONTENT" ]; then
        FULL_CONTENT+="$NEW_CONTENT"
    else
        FULL_CONTENT+="# Нет новых хостов"
    fi

    # Проверяем изменения
    if [ ! -f "$INVENTORY_FILE" ] || ! echo "$FULL_CONTENT" | diff -q "$INVENTORY_FILE" - > /dev/null; then
        echo "Обнаружены изменения, обновляем инвентарь..."
        echo "$FULL_CONTENT" > "$INVENTORY_FILE"

        # Git operations
        cd "$GIT_DIR" || exit 1
        git add inv.ini
        git commit inv.ini -m "update inv: $(date '+%Y-%m-%d %H:%M:%S')"
        git push origin main

        echo "=== ИНВЕНТАРЬ ОБНОВЛЕН И ЗАКОММИТЕН ==="
        echo "Изменения:"
        echo "  Myhosts: $(echo "$MYHOSTS_CONTENT" | grep -c 'ansible_host=') хостов"
        echo "  New: $(echo "$NEW_CONTENT" | grep -c 'ansible_host=') хостов"
        echo "  Удалено: ${#EXISTING_HOSTS[@]} хостов"
    else
        echo "Инвентарь без изменений"
    fi
}

# Запускаем основную функцию
main "$@"
