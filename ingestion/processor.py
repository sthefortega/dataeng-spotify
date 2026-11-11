"""Lo ejecuta cron cada 5 minutos (ver ingestion/crontab). En cada corrida:

1. Lee del crudo las líneas que todavía no ha procesado, según su marcador
   (tabla ingestion_checkpoint).
2. Quita los duplicados (regla 2): un event_id que ya vio no vuelve a contar.
3. Se queda con las reproducciones válidas (regla 1): ms_played >= 30000.
4. Suma los conteos en subscriber_song_play y song_daily_play (día en UTC, regla 3).
5. Mueve su marcador. Los pasos 4 y 5 van en una sola transacción: o se aplican los
   dos, o ninguno. Si la corrida falla, la siguiente retoma desde el último COMMIT.

Cómo quita los duplicados. El consumer escribe un archivo por hora de llegada (UTC), y
un duplicado llega a lo más 5 minutos después que el original. Por eso, para cada línea
nueva, el original siempre está en el archivo de su misma hora o en el de la hora
anterior: basta comparar contra los event_id de esos archivos.

Lo que imprime un programa que ejecuta cron no aparece en ningún lado. Por eso todo,
incluidos los errores, se escribe en /app/logs/processor.log."""

import json
import logging
import os
import re
import sys
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path

import psycopg

# Log: solo a un archivo, porque cron no muestra lo que el programa imprime.
LOG_DIR = Path("/app/logs")
LOG_DIR.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S%z",
    handlers=[logging.FileHandler(LOG_DIR / "processor.log")],
)
log = logging.getLogger("processor")

MIN_VALID_MS = 30_000            # Regla 1
PROCESSOR_LOCK_ID = 2026_11_04   # Evita que dos processors cuenten a la vez (cron y uno a mano)


def parse_hour(path):
    """Hora de llegada (UTC) de un archivo del crudo, sacada de su nombre."""
    match = re.fullmatch(rf"{re.escape(topic)}-(\d{{4}}-\d{{2}}-\d{{2}}T\d{{2}})\.log", path.name)
    if match is None:
        return None
    return datetime.strptime(match.group(1), "%Y-%m-%dT%H").replace(tzinfo=timezone.utc)


def read_lines(path, start, end):
    """Las líneas completas del archivo entre los bytes start y end."""
    with path.open("rb") as f:
        f.seek(start)
        data = f.read(end - start)
    return data.decode("utf-8", errors="replace").splitlines()


def complete_size(path, start):
    """Hasta qué byte el archivo tiene líneas completas. Una línea que el consumer todavía
    está escribiendo (sin salto de línea al final) se deja para la siguiente corrida."""
    with path.open("rb") as f:
        f.seek(start)
        data = f.read()
    last_newline = data.rfind(b"\n")
    return start if last_newline == -1 else start + last_newline + 1


def parse_message(line):
    """Convierte una línea en una reproducción con el formato de la sección 2.3.
    Regresa None si la línea no respeta ese formato."""
    try:
        msg = json.loads(line)
    except json.JSONDecodeError:
        return None
    if not isinstance(msg, dict):
        return None
    event_id = msg.get("event_id")
    subscriber_id = msg.get("subscriber_id")
    song_id = msg.get("song_id")
    played_at = msg.get("played_at")
    ms_played = msg.get("ms_played")
    if not isinstance(event_id, str) or not event_id:
        return None
    # bool es un tipo de int en Python; un true no es un ID ni una duración.
    for value in (subscriber_id, song_id, ms_played):
        if not isinstance(value, int) or isinstance(value, bool):
            return None
    if not isinstance(played_at, str):
        return None
    try:
        played_at = datetime.fromisoformat(played_at)
    except ValueError:
        return None
    if played_at.tzinfo is None:  # sin zona horaria no se sabe qué día es en UTC
        return None
    return event_id, subscriber_id, song_id, played_at, ms_played


def event_ids(lines):
    """Los event_id de unas líneas ya procesadas (las que no se pueden leer se ignoran)."""
    ids = set()
    for line in lines:
        parsed = parse_message(line)
        if parsed is not None:
            ids.add(parsed[0])
    return ids


def run():
    raw_dir = Path("/app/data/raw") / topic
    if not raw_dir.exists():
        # Error conocido: el consumer todavía no ha guardado ningún mensaje.
        log.warning("El crudo %s todavía no existe", raw_dir)
        return

    files = sorted((parse_hour(p), p) for p in raw_dir.glob(f"{topic}-*.log") if parse_hour(p) is not None)

    with psycopg.connect(
        host=os.environ["POSTGRES_HOST"],
        dbname=os.environ["POSTGRES_DB"],
        user=os.environ["POSTGRES_USER"],
        password=os.environ["POSTGRES_PASSWORD"],
    ) as conn:
        # Todo lo que sigue dentro del with es una sola transacción.
        conn.execute("SELECT pg_advisory_xact_lock(%s)", (PROCESSOR_LOCK_ID,))
        checkpoints = dict(conn.execute("SELECT raw_file, byte_offset FROM ingestion_checkpoint").fetchall())

        # Archivos con líneas nuevas completas: (hora, ruta, desde, hasta).
        pending = []
        for hour, path in files:
            start = checkpoints.get(path.name, 0)
            end = complete_size(path, start)
            if end > start:
                pending.append((hour, path, start, end))
        if not pending:
            log.info("Sin mensajes nuevos en el crudo")
            return

        # event_id ya contados en corridas anteriores, de los archivos donde puede estar el
        # original de una línea nueva: desde una hora antes del primer archivo pendiente.
        seen = set()
        window_start = pending[0][0] - timedelta(hours=1)
        for hour, path in files:
            processed = checkpoints.get(path.name, 0)
            if hour >= window_start and processed > 0:
                seen |= event_ids(read_lines(path, 0, processed))

        # IDs que existen en la base, para no romper las llaves foráneas con mensajes de un
        # productor que mande un suscriptor o una canción que no existe (o que ya se borró).
        subscribers = {row[0] for row in conn.execute("SELECT subscriber_id FROM subscribers")}
        songs = {row[0] for row in conn.execute("SELECT song_id FROM songs")}

        stats = Counter()
        subscriber_song = Counter()  # (subscriber_id, song_id) -> reproducciones válidas
        song_day = Counter()         # (song_id, día UTC) -> reproducciones válidas
        for _, path, start, end in pending:
            for line in read_lines(path, start, end):
                stats["leidos"] += 1
                parsed = parse_message(line)
                if parsed is None:
                    stats["mal_formados"] += 1
                    log.warning("Mensaje con formato inválido, descartado: %s", line[:200])
                    continue
                event_id, subscriber_id, song_id, played_at, ms_played = parsed
                if event_id in seen:
                    stats["duplicados"] += 1
                    continue
                seen.add(event_id)
                if ms_played < MIN_VALID_MS:
                    stats["skips"] += 1
                    continue
                if subscriber_id not in subscribers or song_id not in songs:
                    stats["ids_inexistentes"] += 1
                    log.warning("Suscriptor o canción inexistente, descartado: %s", line[:200])
                    continue
                stats["validos"] += 1
                subscriber_song[(subscriber_id, song_id)] += 1
                song_day[(song_id, played_at.astimezone(timezone.utc).date())] += 1

        with conn.cursor() as cur:
            cur.executemany(
                """INSERT INTO subscriber_song_play (subscriber_id, song_id, num_rep)
                   VALUES (%s, %s, %s)
                   ON CONFLICT (subscriber_id, song_id)
                   DO UPDATE SET num_rep = subscriber_song_play.num_rep + EXCLUDED.num_rep""",
                [(sub, song, n) for (sub, song), n in subscriber_song.items()],
            )
            cur.executemany(
                """INSERT INTO song_daily_play (song_id, play_date, num_rep)
                   VALUES (%s, %s, %s)
                   ON CONFLICT (song_id, play_date)
                   DO UPDATE SET num_rep = song_daily_play.num_rep + EXCLUDED.num_rep""",
                [(song, day, n) for (song, day), n in song_day.items()],
            )
            cur.executemany(
                """INSERT INTO ingestion_checkpoint (raw_file, byte_offset, updated_at)
                   VALUES (%s, %s, now())
                   ON CONFLICT (raw_file)
                   DO UPDATE SET byte_offset = EXCLUDED.byte_offset, updated_at = now()""",
                [(path.name, end) for _, path, _, end in pending],
            )
        # Al salir del with sin error, psycopg hace el COMMIT de todo junto.

    discarded = stats["duplicados"] + stats["skips"] + stats["ids_inexistentes"] + stats["mal_formados"]
    log.info(
        "Corrida: %d archivo(s) [%s]; leídos %d, válidos %d, descartados %d "
        "(duplicados %d, skips %d, IDs inexistentes %d, mal formados %d)",
        len(pending), ", ".join(p.name for _, p, _, _ in pending),
        stats["leidos"], stats["validos"], discarded,
        stats["duplicados"], stats["skips"], stats["ids_inexistentes"], stats["mal_formados"],
    )


try:
    # cron no les pasa a sus trabajos las variables del contenedor. Estas llegan porque el
    # command del servicio processor las copia a /etc/environment antes de iniciar cron.
    topic = os.environ["KAFKA_TOPIC"]
    for name in ("POSTGRES_HOST", "POSTGRES_DB", "POSTGRES_USER", "POSTGRES_PASSWORD"):
        os.environ[name]
except KeyError as e:
    log.error(
        "Falta la variable de entorno %s: revisa que esté en environment: del servicio processor "
        "y que su command la copie a /etc/environment",
        e,
    )
    sys.exit(1)

try:
    run()
except psycopg.OperationalError as e:
    # Error conocido: PostgreSQL no acepta conexiones. Nada se aplicó; la siguiente corrida
    # retoma desde el mismo marcador.
    log.error("No se pudo conectar a PostgreSQL; se reintenta en la siguiente corrida: %s", e)
    sys.exit(1)
except Exception:
    log.exception("Error inesperado en la corrida; no se aplicó ningún cambio")
    sys.exit(1)
