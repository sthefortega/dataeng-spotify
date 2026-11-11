# Plataforma de datos de Spotify

Plataforma de datos de una app de música (Spotify) simulada: una base de datos transaccional en PostgreSQL 18 y una ingesta de reproducciones con Kafka, todo con Docker Compose.

## Descripción

Laura, product manager de Spotify, solicitó ordenar los datos de su sistema. La app ofrece suscripciones, y cada suscriptor tiene un perfil, una biblioteca donde guarda canciones y álbumes, y las playlists que crea. El catálogo musical incluye canciones, álbumes y artistas.

Los datos originales fueron normalizados a 3FN para su implementación final en PostgreSQL.

Después, Laura pidió un **top 100 semanal** de canciones y que cada usuario vea **sus 20 canciones más escuchadas**. La app no escribe en la base de datos: cada vez que alguien reproduce una canción, publica un mensaje en Kafka. Este repositorio lee esos mensajes, los guarda en archivos (el crudo) y mantiene los conteos en PostgreSQL. Ningún mensaje se guarda en PostgreSQL: solo los conteos.

## Arquitectura

```
producer ──→ Kafka (tópico streams) ──→ consumer ──→ crudo: un archivo .log por hora
                                                                  │
                                                                  ↓ cron, cada 5 minutos
                                       processor: quita duplicados, filtra y actualiza los conteos ──→ PostgreSQL
```

| Servicio | Imagen | Qué hace |
| --- | --- | --- |
| `postgres` | `postgres:18` | La base de datos: catálogo, suscriptores y conteos |
| `kafka` | `apache/kafka:4.1.0` | Recibe los mensajes y los entrega al consumer |
| `producer` | Propia (`Dockerfile`) | Simula la app: publica reproducciones en el tópico `streams` |
| `consumer` | Propia | Lee el tópico y guarda cada mensaje, tal cual, en el crudo |
| `processor` | Propia | cron ejecuta `processor.py` cada 5 minutos |

Cada reproducción llega como un mensaje JSON:

```json
{"event_id": "8c1e2f4a-6b3d-4e2a-9f1c-2d7b8a5e0c31", "subscriber_id": 1, "song_id": 104,
 "played_at": "2026-11-03T18:42:10-07:00", "ms_played": 187000}
```

## Estructura

```
dataeng-spotify/
├── app_simulator/
│   └── producer.py        # Simula la app de Spotify y publica reproducciones en Kafka
├── ingestion/
│   ├── consumer.py        # Lee Kafka y escribe el crudo
│   ├── processor.py       # Quita duplicados, filtra y actualiza los conteos
│   ├── verify.py          # Comprueba que los conteos coinciden con lo enviado
│   └── crontab            # Ejecuta el processor cada 5 minutos
├── db/
│   ├── 01_schema.sql      # Creación de estructura inicial
│   ├── 02_seed.sql        # Datos proporcionados por Laura y casos adicionales
│   ├── 03_play_counts.sql         # Migración: tablas de conteos de reproducciones
│   └── 04_ingestion_checkpoint.sql  # Migración: marcador de avance del processor
├── docs/
│   ├── diagrama_conceptual.png
│   └── diagrama_er.png
├── .env.example           # Plantilla de las variables de entorno
├── .gitignore
├── .python-version        # Python 3.13, la versión de la imagen
├── Dockerfile             # Imagen de los tres programas de Python
├── docker-compose.yml     # Los cinco servicios
├── pyproject.toml         # Dependencias de Python
├── uv.lock                # Versiones exactas de las dependencias
├── tests.sql              # Pruebas: preguntas de Laura, intentos de romper reglas
│                            y transacciones
└── README.md
```

## Estructura de datos

| Tipo | Tablas |
| --- | --- |
| Entidades | subscriptions, subscribers, profiles, libraries, playlists, songs, albums, artists, countries |
| Tablas de unión | playlist_song, song_artist, song_album, library_song, library_album |
| Conteos de reproducciones (Tarea 4) | subscriber_song_play, song_daily_play |
| Control de la ingesta (Tarea 4) | ingestion_checkpoint |

Las cardinalidades del diagrama están definidas por una restricción de esquema cada una:

| Cardinalidad | Restricción |
| --- | --- |
| Mínimo 1 (ej. todo suscriptor tiene una suscripción) | `NOT NULL` en la llave foránea |
| Máximo 1 en una relación 1 a 1 (ej. un suscriptor, un perfil) | `UNIQUE` en la llave foránea |
| Un par no se repite en una tabla de unión | `PRIMARY KEY` compuesta |
| Supuestos en base a lógica de negocio (precio ≥ 0, rol principal o feat., etc.) | `CHECK` |

### Tablas de conteos

| Tabla | Llave primaria | Columnas | Responde |
| --- | --- | --- | --- |
| `subscriber_song_play` | `(subscriber_id, song_id)` | `num_rep` | Las 20 canciones más escuchadas de un suscriptor |
| `song_daily_play` | `(song_id, play_date)` | `num_rep` | El top 100 semanal |

- `num_rep` es el número de reproducciones válidas, con `CHECK (num_rep > 0)`: una fila solo existe si hay al menos una.
- `play_date` es el día, en UTC, en que ocurrió la reproducción.
- Las dos tablas tienen llaves foráneas a `subscribers` y `songs`.
- `song_daily_play` tiene un índice por `play_date`, porque el top semanal busca por rango de fechas y la llave primaria empieza por `song_id`.

### Cambios respecto al diagrama ER de la Tarea 2

- `countries.name` se declaró `UNIQUE`: dos países no pueden tener el mismo nombre.
- Tarea 4: se agregaron `subscriber_song_play`, `song_daily_play` e `ingestion_checkpoint`. El diagrama ER de `docs/` ya las incluye.

## Supuestos

- Un suscriptor está en una sola suscripción a la vez.
- El precio y los anuncios dependen solo de la suscripción.
- Una canción no se repite dentro de una misma playlist, álbum o biblioteca.
- El orden de las canciones en la celda de una playlist es su posición.
- La duración de las canciones se guarda en segundos.
- Se usan llaves sustitutas (subscriber_id, subscription_id, profile_id, library_id) considerando que el correo o el nombre de una suscripción pueden cambiar. email y subscriptions.name son únicos.
- subscriber_id, profile_id y library_id se asignaron en el orden de la tabla D (ana = 1, luis = 2, marta = 3, diego = 4).
- Todo álbum lo publica exactamente un artista, como en el diagrama conceptual unificado.
- La foto del perfil es opcional (Marta no tiene).

### Supuestos de la ingesta (Tarea 4)

- Una reproducción es válida si `ms_played >= 30000`. Los *skips* llegan, pero no cuentan.
- Dos mensajes con el mismo `event_id` son la misma reproducción. Un duplicado llega a Kafka a lo más 5 minutos después que el original.
- Los días y las semanas se definen en UTC. La semana va de lunes a domingo, y el top semanal usa la última semana completa.
- "La canción más escuchada" es la que tiene más reproducciones válidas desde siempre.
- Un mensaje que no respeta el formato (JSON inválido, campos faltantes o de otro tipo, `played_at` sin zona horaria) se descarta y se anota en el log del processor.
- Un mensaje con un suscriptor o una canción que no existe en la base (por ejemplo, de un suscriptor eliminado) se descarta y se anota en el log: contarlo rompería las llaves foráneas.

### Casos agregados para testing

| Caso | Registro |
| --- | --- |
| Playlist vacía | Viaje (13) |
| Canción sin álbum | Calor de Agosto (108) |
| Suscripción sin suscriptores | Estudiantes (4), $15 al mes |
| Artista sin canciones ni álbumes | Noah Kahan (A11) |

## Decisiones de la ingesta

### Cómo se organiza el crudo

El consumer guarda cada mensaje, tal cual, como una línea de texto. Escribe **un archivo por hora de llegada, en UTC**, en el volumen `crudo`:

```
/app/data/raw/streams/streams-2026-11-11T02.log
/app/data/raw/streams/streams-2026-11-11T03.log
```

- La hora es la del momento en que el consumer recibe el mensaje, no `played_at`: la regla de los duplicados se mide por la llegada, y `played_at` puede ser de hace días (modo sin conexión).
- Organizarlo por hora de llegada permite quitar duplicados revisando solo dos archivos (ver abajo).
- Los archivos no se borran: el crudo es la historia completa de los eventos, que le sirve al análisis.
- El consumer le confirma a Kafka que leyó un mensaje solo **después** de escribirlo en el crudo. Si se cae en medio, Kafka se lo vuelve a entregar: un mensaje puede quedar repetido en el crudo, pero nunca se pierde. La repetición tiene el mismo `event_id` y el processor la descarta.

### Cómo se quitan los duplicados

Un duplicado tiene el mismo `event_id` que el original y llega a lo más 5 minutos después. Como el crudo está organizado por hora de llegada, el original de cualquier línea está en el archivo de su misma hora o en el de la hora anterior.

En cada corrida, el processor:

1. Junta los `event_id` de las líneas ya procesadas de esos archivos (la hora actual y la anterior).
2. Recorre las líneas nuevas en orden. Si su `event_id` ya está en ese conjunto, es un duplicado y se descarta; si no, se agrega al conjunto.
3. Después de quitar duplicados, descarta los *skips*.

Así no necesita guardar ningún estado aparte: los `event_id` ya vistos salen del propio crudo.

### Cómo sabe el processor qué ya procesó: `ingestion_checkpoint`

La tabla `ingestion_checkpoint` guarda, por cada archivo del crudo, hasta qué byte ya se procesó. **No guarda ningún mensaje**, solo una posición.

Va en PostgreSQL, y no en un archivo, porque se actualiza **en la misma transacción** que los conteos: los conteos y el marcador avanzan juntos o no avanzan. Si el processor se cae a la mitad de una corrida, no se aplica nada y la siguiente corrida retoma desde el último `COMMIT`. Con un archivo, una caída entre el `COMMIT` y la escritura del archivo haría que la siguiente corrida contara el mismo lote dos veces.

Otras protecciones del processor:

- Solo lee líneas completas. Una línea que el consumer todavía está escribiendo se deja para la siguiente corrida.
- `flock` en el `crontab` evita que una corrida empiece si la anterior no ha terminado, y un candado de PostgreSQL (`pg_advisory_xact_lock`) evita que dos processors cuenten a la vez, por ejemplo cron y uno ejecutado a mano.

### El producer

- Lee de la base, al iniciar, los IDs de las canciones (con su duración) y de los suscriptores, y usa solo esos.
- `played_at` es un momento al azar de los últimos `MAX_PLAY_AGE_DAYS` días, con la zona horaria de un teléfono simulado (`-07:00`, `-06:00`, `-05:00`, `+00:00` o `+01:00`). Así se prueba que el processor convierte bien a UTC.
- Una reproducción válida dura entre 30 segundos y la duración real de la canción; un *skip*, menos de 30 segundos.
- Un duplicado se envía idéntico al original, con un retraso al azar de entre 0 y `MAX_DUPLICATE_DELAY_SECONDS − 1` segundos (1 segundo de margen para no pasar del límite).
- `sent.log` (volumen `enviados`) guarda cada mensaje original **cuando Kafka confirma** que lo guardó, sin los duplicados. Es la referencia de `verify.py`.

## Variables de entorno

Las credenciales y la configuración van en un archivo `.env`, que no se sube al repositorio. Se puede crear a partir de la plantilla:

```bash
cp .env.example .env
```

| Variable | Qué es | Valor de ejemplo |
| --- | --- | --- |
| `POSTGRES_USER` | Usuario de PostgreSQL | `admin` |
| `POSTGRES_PASSWORD` | Contraseña de ese usuario | `contrasena123` |
| `POSTGRES_DB` | Base de datos que se crea | `spotify` |
| `KAFKA_TOPIC` | Tópico de Kafka de las reproducciones | `streams` |
| `INTERVAL_SECONDS` | Cada cuántos segundos publica el producer un mensaje | `1` |
| `SKIP_RATE` | Proporción de *skips*, entre 0 y 1 | `0.2` |
| `DUPLICATE_RATE` | Proporción de mensajes que se duplican, entre 0 y 1 | `0.1` |
| `MAX_DUPLICATE_DELAY_SECONDS` | Retraso máximo de un duplicado; no debe pasar de 300 | `300` |
| `MAX_PLAY_AGE_DAYS` | Cuántos días hacia atrás puede caer `played_at` | `14` |

## Cómo iniciar todo

Requisitos: Docker y Docker Compose. Los comandos se ejecutan en la carpeta del repositorio.

```bash
docker compose up -d --build
```

La primera vez tarda varios minutos: Docker descarga Kafka y construye la imagen de los programas. Con el volumen vacío, PostgreSQL ejecuta los cuatro archivos de `db/` en orden. Al principio el producer y el consumer muestran errores de conexión mientras PostgreSQL y Kafka terminan de iniciar; es normal.

Para revisar que todo esté corriendo y que la inicialización no tuvo errores:

```bash
docker compose ps
docker compose logs postgres | grep ERROR
```

Si cambias el código, vuelve a ejecutar `docker compose up -d --build`, porque la imagen guarda una copia del código.

### Aplicar una migración a una base que ya tiene datos

Los archivos de `db/` solo se ejecutan con el volumen vacío. Para aplicar una migración a una base con datos:

```bash
docker compose exec postgres psql -U admin -d spotify -f /docker-entrypoint-initdb.d/03_play_counts.sql
docker compose exec postgres psql -U admin -d spotify -f /docker-entrypoint-initdb.d/04_ingestion_checkpoint.sql
```

## Cómo ver qué hace cada programa

Los tres programas escriben su log en el volumen `logs`. El del processor no aparece en `docker compose logs`, porque lo ejecuta cron.

| Qué quieres ver | Comando |
| --- | --- |
| Log del processor (una línea por corrida) | `docker compose exec processor cat /app/logs/processor.log` |
| Log del producer | `docker compose logs --tail 10 producer` |
| Log del consumer | `docker compose logs --tail 10 consumer` |
| Archivos del crudo y sus líneas | `docker compose exec consumer sh -c 'wc -l /app/data/raw/streams/*.log'` |
| Ejecutar el processor sin esperar a cron | `docker compose exec processor /app/.venv/bin/python /app/ingestion/processor.py` |

Cada corrida del processor anota cuántos mensajes leyó, cuántos contó y cuántos descartó, y por qué:

```
Corrida: 1 archivo(s) [streams-2026-11-11T02.log]; leídos 166, válidos 100, descartados 66 (duplicados 38, skips 28, IDs inexistentes 0, mal formados 0)
```

## Verificación (`verify.py`)

`verify.py` comprueba que, por canción, las reproducciones válidas de `sent.log` son iguales a los conteos de la base, y que el total de `subscriber_song_play` es igual al de `song_daily_play`. Muestra `OK` si todo coincide, o la lista de diferencias.

Se ejecuta en el contenedor del **processor**, que tiene las variables de PostgreSQL y ve `sent.log` en solo lectura a través del volumen `enviados`.

Para obtener la evidencia:

```bash
docker compose down -v && docker compose up -d --build   # 1. Partir de cero
# 2. Dejar correr todo al menos 15 minutos
docker compose stop producer                             # 3. Detener el producer
# 4. Esperar la siguiente corrida del processor (revisar su log)
docker compose exec processor /app/.venv/bin/python /app/ingestion/verify.py   # 5. Verificar
```

Salida obtenida:

```
song_id    sent.log   subscriber_song_play   song_daily_play
101              60                     60                60
102              65                     65                65
103              66                     66                66
104              72                     72                72
105              67                     67                67
106              64                     64                64
107              51                     51                51
108              51                     51                51
TOTAL           496                    496               496
(629 mensajes originales en sent.log, 496 válidos)
OK
```

`verify.py` se debe ejecutar antes de `tests.sql`: la parte c de las pruebas elimina a un suscriptor, y sus conteos desaparecen de `subscriber_song_play` pero no de `sent.log` ni de `song_daily_play`.

## Ejecución de testing

```bash
docker compose exec postgres psql -U admin -d spotify -f /tests.sql
```

Se usan los valores de `POSTGRES_USER` y `POSTGRES_DB` de `.env` y cada prueba tiene un comentario con el resultado esperado.

- a) Responde preguntas de Laura sobre insights de los datos, incluidos el top 100 semanal, las 20 canciones más escuchadas de un suscriptor y la canción más escuchada.
- b) Intentos de romper las restricciones de esquema, errores esperados.
- c) Registro y eliminación de un suscriptor con transacciones, evaluando casos exitosos y fallidos. La eliminación también borra sus conteos de `subscriber_song_play` y muestra que el top semanal no cambia.

Para repetir las pruebas, se debe reiniciar desde cero porque la sección c modifica datos. Se puede reiniciar utilizando:

```bash
docker compose down -v && docker compose up -d --build
```
