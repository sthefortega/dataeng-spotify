"""Lee el tópico de Kafka y guarda cada mensaje, tal cual, como una línea del crudo.

Organización del crudo: un archivo por hora de llegada, en UTC:
    /app/data/raw/<tópico>/<tópico>-AAAA-MM-DDTHH.log
La hora es la del momento en que el consumer recibe el mensaje, no played_at. Así el
processor sabe, por el nombre del archivo, cuándo llegó cada mensaje, y puede quitar los
duplicados (que llegan a lo más 5 minutos después del original) revisando solo el archivo
de la hora actual y el de la hora anterior.

El consumer no interpreta ni filtra nada: escribe el texto del mensaje tal cual llegó.

Cada acción y cada error se anotan en /app/logs/consumer.log."""

import logging
import os
import signal
import sys
from datetime import datetime, timezone
from pathlib import Path

from confluent_kafka import Consumer, KafkaError

# Log: se escribe en un archivo y también en la consola, para verlo con docker compose logs.
LOG_DIR = Path("/app/logs")
LOG_DIR.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S%z",
    handlers=[logging.FileHandler(LOG_DIR / "consumer.log"), logging.StreamHandler()],
)
log = logging.getLogger("consumer")


def raw_file_for(arrival):
    """Archivo del crudo que corresponde a una hora de llegada (UTC)."""
    return RAW_DIR / f"{topic}-{arrival:%Y-%m-%dT%H}.log"


def stop(signum, frame):
    """docker compose stop manda SIGTERM: se termina el mensaje actual y se sale en orden."""
    global running
    running = False


try:
    topic = os.environ["KAFKA_TOPIC"]
    bootstrap_servers = os.environ["KAFKA_BOOTSTRAP_SERVERS"]
except KeyError as e:
    log.error("Falta la variable de entorno %s: revisa tu .env y environment: en docker-compose.yml", e)
    sys.exit(1)

# /app/data es el volumen crudo, que el processor también ve.
RAW_DIR = Path("/app/data/raw") / topic
try:
    RAW_DIR.mkdir(parents=True, exist_ok=True)
except OSError:
    log.exception("No se pudo crear la carpeta del crudo %s; el consumer termina", RAW_DIR)
    sys.exit(1)

consumer = Consumer({
    "bootstrap.servers": bootstrap_servers,
    "group.id": "ingestion",
    "auto.offset.reset": "earliest",
    "allow.auto.create.topics": True,
    # El offset de un mensaje se marca como leído solo después de escribirlo en el crudo
    # (store_offsets más abajo). Si el consumer se cae antes, Kafka se lo vuelve a entregar:
    # puede quedar repetido en el crudo, pero nunca se pierde. El processor quita repetidos.
    "enable.auto.offset.store": False,
})
consumer.subscribe([topic])
log.info("Suscrito al tópico %s; el crudo se escribe en %s, un archivo por hora (UTC)", topic, RAW_DIR)

running = True
signal.signal(signal.SIGTERM, stop)
current_path = None
raw = None

try:
    while running:
        msg = consumer.poll(timeout=1.0)
        if msg is None:
            continue
        if msg.error():
            if msg.error().code() == KafkaError.UNKNOWN_TOPIC_OR_PART:
                # Error conocido al iniciar: el consumer se suscribió antes de que existiera el tópico.
                # Con allow.auto.create.topics, Kafka lo crea y el consumer sigue esperando mensajes.
                log.warning("El tópico %s todavía no existe; se crea automáticamente: %s", topic, msg.error())
            else:
                log.error("Kafka reportó un error: %s", msg.error())
            continue

        # Al cambiar la hora, se cierra el archivo anterior y se abre el de la hora nueva.
        path = raw_file_for(datetime.now(timezone.utc))
        if path != current_path:
            if raw is not None:
                raw.close()
            raw = path.open("a", encoding="utf-8")
            current_path = path
            log.info("Escribiendo el crudo en %s", path.name)

        line = msg.value().decode("utf-8")
        raw.write(line + "\n")
        raw.flush()  # la línea queda escrita completa para el processor
        consumer.store_offsets(message=msg)
        log.info("Guardado en el crudo (offset %s): %s", msg.offset(), line)
except OSError:
    # Error conocido: no se pudo escribir en el crudo (por ejemplo, el disco está lleno).
    log.exception("No se pudo escribir en el crudo %s; el consumer termina", current_path)
    sys.exit(1)
except Exception:
    log.exception("Error inesperado; el consumer termina y Docker lo volverá a iniciar")
    sys.exit(1)

# Salida en orden: cierra el archivo y le confirma a Kafka hasta dónde se guardó.
if raw is not None:
    raw.close()
consumer.close()
log.info("Consumer detenido")
