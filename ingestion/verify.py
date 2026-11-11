"""Verifica que los conteos de la base de datos coinciden con los eventos únicos enviados.

Comprueba dos cosas, por canción:
1. Las reproducciones válidas de sent.log (ms_played >= 30000) son iguales a los conteos de
   la base de datos.
2. El total de subscriber_song_play es igual al de song_daily_play.

Muestra OK si todo coincide, o la lista de diferencias. Termina con código 0 si todo
coincide y 1 si no.

Se ejecuta en el contenedor del processor, que ve sent.log en /app/sent (volumen enviados)
y tiene las variables de PostgreSQL:

    docker compose exec processor /app/.venv/bin/python /app/ingestion/verify.py

Para que coincida: parte de cero (docker compose down -v), deja correr todo, detén el
producer y espera a que el processor haga su siguiente corrida. Si eliminas un suscriptor
(tests.sql), sus conteos desaparecen de la base pero no de sent.log, y ya no coincidirá."""

import json
import logging
import os
import sys
from collections import Counter
from pathlib import Path

import psycopg

# Log: en la consola, para ver el resultado, y en un archivo, para conservarlo.
LOG_DIR = Path("/app/logs")
LOG_DIR.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(message)s",
    handlers=[logging.FileHandler(LOG_DIR / "verify.log"), logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("verify")

SENT_FILE = Path("/app/sent/sent.log")
MIN_VALID_MS = 30_000  # Regla 1


def read_sent():
    """Reproducciones válidas por canción, según sent.log."""
    expected = Counter()
    originals = 0
    with SENT_FILE.open(encoding="utf-8") as f:
        for line in f:
            if not line.strip():
                continue
            msg = json.loads(line)
            originals += 1
            if msg["ms_played"] >= MIN_VALID_MS:
                expected[msg["song_id"]] += 1
    return originals, expected


def read_db():
    """Total por canción en cada una de las dos tablas."""
    with psycopg.connect(
        host=os.environ["POSTGRES_HOST"],
        dbname=os.environ["POSTGRES_DB"],
        user=os.environ["POSTGRES_USER"],
        password=os.environ["POSTGRES_PASSWORD"],
    ) as conn:
        by_subscriber = dict(conn.execute(
            "SELECT song_id, sum(num_rep)::int FROM subscriber_song_play GROUP BY song_id"
        ).fetchall())
        by_day = dict(conn.execute(
            "SELECT song_id, sum(num_rep)::int FROM song_daily_play GROUP BY song_id"
        ).fetchall())
    return by_subscriber, by_day


try:
    originals, expected = read_sent()
    by_subscriber, by_day = read_db()
except FileNotFoundError:
    log.error("No existe %s: el producer todavía no ha enviado nada, o el volumen enviados no está conectado", SENT_FILE)
    sys.exit(1)
except KeyError as e:
    log.error("Falta la variable de entorno %s, o una línea de sent.log no tiene ese campo", e)
    sys.exit(1)
except psycopg.OperationalError as e:
    log.error("No se pudo conectar a PostgreSQL: %s", e)
    sys.exit(1)

songs = sorted(set(expected) | set(by_subscriber) | set(by_day))
differences = []
log.info("%-8s %10s %22s %17s", "song_id", "sent.log", "subscriber_song_play", "song_daily_play")
for song in songs:
    sent_n, sub_n, day_n = expected.get(song, 0), by_subscriber.get(song, 0), by_day.get(song, 0)
    mark = "" if sent_n == sub_n == day_n else "  <-- diferente"
    log.info("%-8s %10d %22d %17d%s", song, sent_n, sub_n, day_n, mark)
    if sent_n != sub_n:
        differences.append(f"canción {song}: sent.log tiene {sent_n} válidas y subscriber_song_play {sub_n}")
    if sent_n != day_n:
        differences.append(f"canción {song}: sent.log tiene {sent_n} válidas y song_daily_play {day_n}")
    if sub_n != day_n:
        differences.append(f"canción {song}: subscriber_song_play tiene {sub_n} y song_daily_play {day_n}")
log.info(
    "%-8s %10d %22d %17d",
    "TOTAL", sum(expected.values()), sum(by_subscriber.values()), sum(by_day.values()),
)
log.info("(%d mensajes originales en sent.log, %d válidos)", originals, sum(expected.values()))

if differences:
    log.info("DIFERENCIAS:")
    for difference in differences:
        log.info("- %s", difference)
    sys.exit(1)
log.info("OK")
