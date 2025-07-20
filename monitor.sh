#!/bin/bash

GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' 

safe_read() {
    if [ -r "$1" ]; then
        cat "$1"
    else
        echo "[недоступно]"
    fi
}

get_username() {
    local uid=$1
    local name

    name=$(awk -F: -v uid="$uid" '$3 == uid {print $1}' /etc/passwd 2>/dev/null)

    echo "${name:-$uid}"
}

get_top_process() {
    local top_line=$(ps aux --sort=-%cpu 2>/dev/null | awk 'NR==2')
    
    if [ -z "$top_line" ]; then
        top_line=$(ps -eo pid,user,%cpu,%mem,comm --sort=-%cpu 2>/dev/null | awk 'NR==2')
    fi
    
    if [ -z "$top_line" ]; then
        local max_cpu=0
        local top_pid=""
        
        for pid in /proc/[0-9]*/; do
            pid=${pid%/}
            pid=${pid##*/}
            
            if [ -f "/proc/$pid/stat" ]; then
                local cpu_usage=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null)
                if [ -n "$cpu_usage" ] && [ "$cpu_usage" -gt "$max_cpu" ]; then
                    max_cpu=$cpu_usage
                    top_pid=$pid
                fi
            fi
        done
        
        if [ -n "$top_pid" ]; then
            local stat=($(safe_read "/proc/$top_pid/stat"))
            local uid=$(stat -c '%u' "/proc/$top_pid" 2>/dev/null || echo "0")
            local user=$(get_username "$uid")
            local cpu_percent=$(awk -v ticks="$max_cpu" -v hertz="$(getconf CLK_TCK)" \
                              'BEGIN { printf "%.1f", ticks/hertz }' /dev/null)
            local mem_percent=$(awk -v rss="${stat[23]}" -v pagesize="$(getconf PAGESIZE)" -v memtotal="$(grep MemTotal /proc/meminfo | awk '{print $2}')" \
                              'BEGIN { printf "%.1f", rss*pagesize/memtotal/1024 }' /dev/null)
            local cmd=$(safe_read "/proc/$top_pid/cmdline" | tr '\0' ' ' | sed 's/ $//')
            
            echo "$user $top_pid $cpu_percent $mem_percent $cmd"
            return
        fi
    fi
    
    echo "$top_line"
}

while true; do
    clear

    echo -e "${CYAN}======== СИСТЕМНАЯ ИНФОРМАЦИЯ ========${NC}"
    
    echo -e "${GREEN}Аптайм:${NC}"
    uptime_sec=$(awk '{print int($1)}' /proc/uptime)
    uptime_days=$((uptime_sec / 86400))
    uptime_hours=$(( (uptime_sec % 86400) / 3600 ))
    uptime_mins=$(( (uptime_sec % 3600) / 60 ))
    echo "Система работает: ${uptime_days}д ${uptime_hours}ч ${uptime_mins}мин (${uptime_sec} секунд)"

    echo -e "\n${GREEN}Средняя нагрузка за 1, 5, 15 мин:${NC}"
    read -r load1 load5 load15 _ < /proc/loadavg
    printf "1 мин: %.2f  | 5 мин: %.2f  | 15 мин: %.2f\n" "$load1" "$load5" "$load15"

    echo -e "\n${GREEN}Использование памяти:${NC}"
    {
        grep -E 'MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree' /proc/meminfo | \
        while read -r line; do
            key=$(echo "$line" | awk '{print $1}')
            value=$(echo "$line" | awk '{print $2}')
            unit=$(echo "$line" | awk '{print $3}')
            printf "%-15s %'d %s\n" "$key:" "$value" "$unit"
        done
    } 2>/dev/null || echo "Не удалось получить информацию о памяти"

    echo -e "\n${GREEN}Статистика CPU:${NC}"
    awk '/^cpu / {
        total = $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9
        printf "User: %d (%.1f%%) | System: %d (%.1f%%) | Idle: %d (%.1f%%)\n", 
               $2, 100*$2/total, $4, 100*$4/total, $5, 100*$5/total
    }' /proc/stat

    echo -e "\n${CYAN}======== ПРОЦЕСС — ЛИДЕР ПО CPU ========${NC}"

    top_line=$(get_top_process)
    
    if [ -z "$top_line" ]; then
        echo -e "${RED}Не удалось получить информацию о процессах${NC}"
        echo -e "${BLUE}Возможные причины:${NC}"
        echo "1. Нет прав на чтение /proc"
        echo "2. Команда ps недоступна"
        echo "3. В системе нет активных процессов"
        echo -e "\n${CYAN}=========================================${NC}"
        sleep 5
        continue
    fi

    top_pid=$(echo "$top_line" | awk '{print $2}')
    cpu_usage=$(echo "$top_line" | awk '{print $3}')
    mem_usage=$(echo "$top_line" | awk '{print $4}')
    uid=$(echo "$top_line" | awk '{print $1}')
    user=$(get_username "$uid")
    
    if [ -r "/proc/$top_pid/cmdline" ]; then
        cmdline=$(tr '\0' ' ' < "/proc/$top_pid/cmdline" | sed 's/ $//')
        [ -z "$cmdline" ] && cmdline=$(safe_read "/proc/$top_pid/comm")
    else
        cmdline="[недоступно]"
    fi

    echo -e "${GREEN}Общие сведения:${NC}"
    echo -e "PID: ${YELLOW}${top_pid}${NC}"
    echo -e "Пользователь: ${YELLOW}${user}${NC}"
    echo -e "CPU: ${RED}${cpu_usage}%${NC}"
    echo -e "MEM: ${RED}${mem_usage}%${NC}"
    echo -e "Команда запуска: ${YELLOW}${cmdline}${NC}"

    if [ ! -d "/proc/$top_pid" ]; then
        echo -e "\n${RED}Процесс уже завершился.${NC}"
        echo -e "\n${CYAN}=========================================${NC}"
        echo "Обновление через 5 секунд..."
        sleep 5
        continue
    fi

    echo -e "\n${GREEN}Статус процесса:${NC}"
    grep -E '^Name:|^State:|^PPid:|^Threads:|^VmSize:|^VmRSS:' "/proc/$top_pid/status" 2>/dev/null | \
    while read -r line; do
        key=$(echo "$line" | cut -d: -f1)
        value=$(echo "$line" | cut -d: -f2- | xargs)
        echo -e "${key}: ${YELLOW}${value}${NC}"
    done

    echo -e "\n${GREEN}Информация из /proc/${top_pid}/stat:${NC}"
    if [ -r "/proc/$top_pid/stat" ]; then
        read -r -a stat_array < "/proc/$top_pid/stat"
        printf "PID: %s | Имя: %s | Состояние: %s | PPID: %s | Приоритет: %s | Nice: %s\n" \
               "${stat_array[0]}" "${stat_array[1]}" "${stat_array[2]}" \
               "${stat_array[3]}" "${stat_array[17]}" "${stat_array[18]}"
    else
        echo "[недоступно]"
    fi

    echo -e "\n${GREEN}Рабочая директория процесса:${NC}"
    if [ -e "/proc/$top_pid/cwd" ]; then
        readlink "/proc/$top_pid/cwd" || echo "[недоступно]"
    else
        echo "[недоступно]"
    fi

    echo -e "\n${GREEN}Открытые файлы (первые 5):${NC}"
    if [ -d "/proc/$top_pid/fd" ]; then
        ls -l "/proc/$top_pid/fd" 2>/dev/null | head -n 6 | \
        awk '{if(NR>1) print $9 " -> " $11}'
        count=$(ls -1 "/proc/$top_pid/fd" 2>/dev/null | wc -l)
        [ "$count" -gt 5 ] && echo "... и ещё $((count-5))"
    else
        echo "[недоступно]"
    fi

    echo -e "\n${CYAN}=========================================${NC}"
    echo "Обновление через 5 секунд..."
    sleep 5
done