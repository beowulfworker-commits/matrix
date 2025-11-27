# Matrix Synapse в Docker (Synapse + PostgreSQL + Caddy)

Этот репозиторий содержит docker-стек для развёртывания Matrix Synapse с базой данных PostgreSQL и обратным прокси Caddy, автоматически получающим TLS-сертификаты Let's Encrypt.

## Требования
- Ubuntu 22.04
- Публичный домен, который будет использоваться как `MATRIX_SERVER_NAME`
- Открытые входящие порты 80, 443 и 8448

## Подготовка репозитория
1. Отредактируйте `install-matrix.sh`, заменив значение `REPO_URL` на реальный URL этого репозитория.
2. Закоммитьте и запушьте изменения.

## Установка на сервере
Скрипт можно запускать напрямую из репозитория. Перед первым использованием убедитесь, что `install-matrix.sh` исполняемый (`chmod +x install-matrix.sh`). Пример запуска:

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/YOUR_GITHUB_USER/YOUR_REPO/main/install-matrix.sh")
```

Установка проходит в три этапа:
1. **Первый запуск**: устанавливает Docker и зависимости, клонирует репозиторий, создаёт `.env` из `.env.example` и завершает работу с просьбой отредактировать `.env`.
2. **Второй запуск**: генерирует `data/synapse/homeserver.yaml` и завершает работу с просьбой настроить подключение к PostgreSQL и HTTP listener.
3. **Третий и последующие запуски**: выполняют `docker compose pull` и `docker compose up -d` для обновления и запуска стека.

## Создание первого пользователя
После запуска стека создайте первого пользователя командой:

```bash
docker exec -it matrix-synapse register_new_matrix_user -c /data/homeserver.yaml http://localhost:8008
```

При создании первого пользователя ответьте `yes` на вопрос о правах администратора, чтобы назначить учётную запись админом.
