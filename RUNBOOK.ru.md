# Runbook - ручной запуск на clore (устаревший путь)

**Статус: резервный вариант.** Основной путь теперь готовый образ
`ghcr.io/promotezor/llm-rig:latest`, он поднимает все сам за три-четыре минуты. Этот runbook
нужен, только если образ почему-то не пошел на конкретном хосте, или чтобы понять, что именно
делает образ внутри. Скрипт `scripts/setup-nodocker.sh` выполняет все шаги ниже автоматически.
Проверен 25 ноября 2026 на образе Ubuntu Jupyter.

Пока не собрали GHCR-образ, этот путь работает. Записан 26.11.2026, проверен на боксе
RTX 5090 32GB (host 25412, Германия).

## Важное про clore

- стандартный rental это Docker-контейнер, НЕ полный сервер
- docker внутри не запускается (в CapEff нет SYS_ADMIN/NET_ADMIN)
- mount tmpfs нельзя (нет SYS_ADMIN)
- /dev/shm смонтирован noexec (программы оттуда не запускать), но это tmpfs 48GB - модель туда
- все в /dev/shm стирается при остановке контейнера, на реальный диск чаты не пишутся

## Что качаем

Бинарник (prebuilt llama.cpp, CUDA 12.8, sm_120 под RTX 5090):
https://github.com/ai-dock/llama.cpp-cuda/releases/download/v1.0.0/llama.cpp-v1.0.0-cuda-12.8-amd64.tar.gz

Модель (ThinkingCap uncensored, IQ4_XS, ~15.3GB):
https://huggingface.co/mradermacher/ThinkingCap-Qwen3.8-27B-Uncensored-Heretic-GGUF/resolve/main/ThinkingCap-Qwen3.8-27B-Uncensored-Heretic.IQ4_XS.gguf

## Порядок

1. Модель в /dev/shm фоном, бинарник в /root
2. Распаковать бинарник, прописать PATH и LD_LIBRARY_PATH
3. Поставить системные пакеты
4. Запустить llama-server
5. С ноута туннель, чат в браузере на http://127.0.0.1:8080/

## Команды по шагам

Модель в фон (качается ~15 мин):

```bash
cd /dev/shm && nohup wget -qc "https://huggingface.co/mradermacher/ThinkingCap-Qwen3.8-27B-Uncensored-Heretic-GGUF/resolve/main/ThinkingCap-Qwen3.8-27B-Uncensored-Heretic.IQ4_XS.gguf" >/dev/null 2>&1 &
```

Бинарник:

```bash
cd /root && wget -q "https://github.com/ai-dock/llama.cpp-cuda/releases/download/v1.0.0/llama.cpp-v1.0.0-cuda-12.8-amd64.tar.gz" -O llama.tar.gz && tar xzf llama.tar.gz
```

Пути (чтобы работало просто llama-server):

```bash
echo 'export PATH=/root/cuda-12.8:$PATH LD_LIBRARY_PATH=/root/cuda-12.8' >> ~/.bashrc && source ~/.bashrc
```

Системные пакеты (в этом порядке):

```bash
apt-get update -qq
apt-get install -y -qq libgomp1
wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb -O /tmp/cuda-keyring.deb && dpkg -i /tmp/cuda-keyring.deb && apt-get update -qq
apt-get install -y -qq cuda-cudart-12-8 libcublas-12-8 libnccl2
```

Проверка, что бинарник собран и все библиотеки на месте:

```bash
llama-server --version 2>&1 | head -5
ldd /root/cuda-12.8/llama-server /root/cuda-12.8/libllama-server-impl.so /root/cuda-12.8/libggml-cuda.so.1.0.0 2>&1 | grep -i 'not found' | sort -u
```

Запуск модели (фоном):

```bash
cd /dev/shm && nohup llama-server -m /dev/shm/ThinkingCap-Qwen3.8-27B-Uncensored-Heretic.IQ4_XS.gguf -c 262144 -ngl 99 --cache-type-k q8_0 --cache-type-v q8_0 --host 127.0.0.1 --port 8080 > /dev/shm/llama.log 2>&1 &
```

Готовность - в логе строка server is listening, в nvidia-smi ~25GB занято:

```bash
tail -25 /dev/shm/llama.log
nvidia-smi
```

Туннель с мака (в другом окне терминала):

```bash
ssh -i ~/.ssh/id_ed25519_servers -o IdentitiesOnly=yes -p 1684 -L 8080:127.0.0.1:8080 root@n1.de.clorecloud.net
```

Чат - в браузере http://127.0.0.1:8080/ (встроенный веб-чат llama-server).

## Флаги запуска (смысл)

- `-c 262144` - контекст 256k
- `-ngl 99` - все слои в GPU
- `--cache-type-k/v q8_0` - KV-кеш в 8 бит, иначе 256k не влезает в 32GB
- `--host 127.0.0.1` - только локалхост, наружу ничего

## Скорость

77 tok/s на генерации (первый запрос медленный, это прогрев CUDA-ядер).

## Что дальше

Собрать образ в GitHub Actions (linux/amd64, CUDA 12.8, llama-server + прокси), запушить в GHCR,
вставлять в clore поле Custom. Убирает весь ручной монтаж. GitHub Actions для публичных реп бесплатный.
