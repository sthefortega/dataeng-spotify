"""Simula la app de Spotify: cada INTERVAL_SECONDS segundos alguien reproduce una canción,
y se publica en Kafka un mensaje con esa reproducción.

Para probar la ingesta, una parte de los mensajes son skips (menos de 30 segundos) y otra
parte se envía dos veces (duplicados), con un retraso de hasta MAX_DUPLICATE_DELAY_SECONDS.

Cada mensaje original que Kafka confirma se anota en /app/sent/sent.log, sin los duplicados:
es la referencia con la que verify.py compara los conteos.

Cada acción y cada error se anotan en /app/logs/producer.log."""

import heapq
import json
import logging
import os
import random
import signal
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import psycopg
from confluent_kafka import Producer

# Log: se escribe en un archivo y también en la consola, para verlo con docker compose logs.
LOG_DIR = Path("/app/logs")
LOG_DIR.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S%z",
    handlers=[logging.FileHandler(LOG_DIR / "producer.log"), logging.StreamHandler()],
)
log = logging.getLogger("producer")

# sent.log: los mensajes originales que Kafka confirmó, uno por línea.
SENT_DIR = Path("/app/sent")
SENT_FILE = SENT_DIR / "sent.log"

MIN_VALID_MS = 30_000  # Regla 1: una reproducción vale si dura al menos 30 segundos

# Zonas horarias de los teléfonos simulados. played_at llega con la hora local del
# teléfono; el processor debe convertirla a UTC (regla 3).
PHONE_TIMEZONES = [timezone(timedelta(hours=h)) for h in (-7, -6, -5, 0, 1)]


def read_catalog():
    """Lee de PostgreSQL las canciones (con su duración) y los suscriptores que existen."""
    with psycopg.connect(
        host=os.environ["POSTGRES_HOST"],
        dbname=os.environ["POSTGRES_DB"],
        user=os.environ["POSTGRES_USER"],
        password=os.environ["POSTGRES_PASSWORD"],
    ) as conn:
        songs = conn.execute("SELECT song_id, duration_seconds FROM songs ORDER BY song_id").fetchall()
        subscribers = [
            row[0] for row in conn.execute("SELECT subscriber_id FROM subscribers ORDER BY subscriber_id")
        ]
    return songs, subscribers


def read_rate(name):
    """Lee una proporción del .env y comprueba que esté entre 0 y 1."""
    value = float(os.environ[name])
    if not 0 <= value <= 1:
        raise ValueError(f"{name} debe estar entre 0 y 1, y vale {value}")
    return value


def new_play():
    """Inventa una reproducción con el formato fijo de la sección 2.3."""
    song_id, duration_seconds = random.choice(songs)
    if random.random() < skip_rate:
        ms_played = random.randint(1_000, MIN_VALID_MS - 1)  # skip: llega, pero no cuenta
    else:
        ms_played = random.randint(MIN_VALID_MS, max(MIN_VALID_MS, duration_seconds * 1000))

    # Modo sin conexión: la reproducción ocurrió en algún momento de los últimos días.
    seconds_ago = random.uniform(0, max_play_age_days * 86_400)
    played_at = datetime.now(timezone.utc) - timedelta(seconds=seconds_ago)
    played_at = played_at.astimezone(random.choice(PHONE_TIMEZONES))

    return {
        "event_id": str(uuid.uuid4()),
        "subscriber_id": random.choice(subscribers),
        "song_id": song_id,
        "played_at": played_at.isoformat(timespec="seconds"),
        "ms_played": ms_played,
    }


def report_original(err, msg):
    """Kafka llama a esta función cuando confirma, o no, que guardó un mensaje original."""
    value = msg.value().decode("utf-8")
    if err is not None:
        # No se anota en sent.log ni se duplica: Kafka no lo tiene.
        log.error("Kafka no guardó el mensaje %s: %s", value, err)
        return
    sent_file.write(value + "\n")
    sent_file.flush()
    log.info("Enviado: %s", value)

    # Una parte de los originales se vuelve a enviar, idéntica, más tarde. El retraso se
    # cuenta desde que Kafka confirmó el original; se deja 1 segundo de margen para que el
    # duplicado nunca llegue más de MAX_DUPLICATE_DELAY_SECONDS después.
    if random.random() < duplicate_rate:
        delay = random.uniform(0, max(0.0, max_duplicate_delay - 1))
        heapq.heappush(pending_duplicates, (time.monotonic() + delay, value))


def report_duplicate(err, msg):
    """Kafka llama a esta función cuando confirma, o no, que guardó un duplicado."""
    value = msg.value().decode("utf-8")
    if err is not None:
        log.error("Kafka no guardó el duplicado %s: %s", value, err)
    else:
        log.info("Duplicado enviado: %s", value)


def stop(signum, frame):
    """docker compose stop manda SIGTERM: se termina la vuelta actual y se sale en orden."""
    global running
    running = False


# Al iniciar: configuración y catálogo.
try:
    topic = os.environ["KAFKA_TOPIC"]
    interval = float(os.environ["INTERVAL_SECONDS"])
    skip_rate = read_rate("SKIP_RATE")
    duplicate_rate = read_rate("DUPLICATE_RATE")
    max_duplicate_delay = float(os.environ["MAX_DUPLICATE_DELAY_SECONDS"])
    max_play_age_days = float(os.environ["MAX_PLAY_AGE_DAYS"])
    if interval <= 0:
        raise ValueError(f"INTERVAL_SECONDS debe ser mayor que 0, y vale {interval}")
    if not 0 <= max_duplicate_delay <= 300:
        raise ValueError(f"MAX_DUPLICATE_DELAY_SECONDS debe estar entre 0 y 300, y vale {max_duplicate_delay}")
    if max_play_age_days <= 0:
        raise ValueError(f"MAX_PLAY_AGE_DAYS debe ser mayor que 0, y vale {max_play_age_days}")
    producer = Producer({"bootstrap.servers": os.environ["KAFKA_BOOTSTRAP_SERVERS"]})
    songs, subscribers = read_catalog()
except KeyError as e:
    log.error("Falta la variable de entorno %s: revisa tu .env y environment: en docker-compose.yml", e)
    sys.exit(1)
except ValueError as e:
    log.error("Valor inválido en el .env: %s", e)
    sys.exit(1)
except psycopg.OperationalError as e:
    # Error conocido al iniciar: PostgreSQL todavía no acepta conexiones.
    # El programa termina con error y Docker lo vuelve a iniciar (restart: on-failure).
    log.error("No se pudo conectar a PostgreSQL; Docker volverá a iniciar el producer: %s", e)
    sys.exit(1)
except Exception:
    log.exception("Error inesperado al iniciar")
    sys.exit(1)

if not songs or not subscribers:
    log.error("No hay canciones o suscriptores en la base de datos: no se puede simular nada")
    sys.exit(1)

try:
    SENT_DIR.mkdir(parents=True, exist_ok=True)
    sent_file = SENT_FILE.open("a", encoding="utf-8")
except OSError as e:
    log.error("No se pudo abrir %s: %s", SENT_FILE, e)
    sys.exit(1)

log.info(
    "Catálogo: %d canciones y %d suscriptores. Publicando en %s cada %s s "
    "(skips %.0f %%, duplicados %.0f %%, retraso máximo %s s, últimos %s días)",
    len(songs), len(subscribers), topic, interval,
    skip_rate * 100, duplicate_rate * 100, max_duplicate_delay, max_play_age_days,
)

running = True
signal.signal(signal.SIGTERM, stop)
pending_duplicates = []  # (momento en que se envía, mensaje), ordenados por momento

# Un original cada INTERVAL_SECONDS segundos, y cada duplicado cuando le toca.
try:
    next_original = time.monotonic()
    while running:
        now = time.monotonic()
        while pending_duplicates and pending_duplicates[0][0] <= now:
            _, value = heapq.heappop(pending_duplicates)
            producer.produce(topic, value=value, on_delivery=report_duplicate)
        if now >= next_original:
            producer.produce(topic, value=json.dumps(new_play()), on_delivery=report_original)
            next_original += interval
        # poll() entrega las confirmaciones de Kafka (llama a report_*) y espera un poco.
        next_event = next_original if not pending_duplicates else min(next_original, pending_duplicates[0][0])
        producer.poll(max(0.0, min(0.5, next_event - time.monotonic())))
except Exception:
    log.exception("Error inesperado; el producer termina y Docker lo volverá a iniciar")
    sys.exit(1)

# Salida en orden: espera las confirmaciones pendientes para que sent.log quede completo.
remaining = producer.flush(10)
sent_file.close()
log.info(
    "Producer detenido. Mensajes sin confirmar: %d. Duplicados programados que no se enviaron: %d",
    remaining, len(pending_duplicates),
)
