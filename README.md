# Base de datos de Spotify

Base de datos transaccional de una app de música (Spotify) simulada, implementada en PostgreSQL 18.

## Descripción

Laura, product manager de Spotify, solicitó ordenar los datos de su sistema. La app ofrece suscripciones, y cada suscriptor tiene un perfil, una biblioteca donde guarda canciones y álbumes, y las playlists que crea. El catálogo musical incluye canciones, álbumes y artistas.

Los datos originales fueron normalizados a 3FN para su implementación final en PostgreSQL.

## Estructura

```
spotify-db/
├── db/
│   ├── 01_schema.sql      # Creación de estructura inicial.
│   └── 02_seed.sql        # Datos proporcionados por Laura y casos adicionales.
├── docs/
│   ├── diagrama_conceptual.png
│   └── diagrama_er.png
├── .env.example           # Plantilla de las variables de entorno
├── .gitignore             
├── docker-compose.yml     # Contenedor de PostgreSQL 18
├── tests.sql              # Pruebas: resuelve preguntas de Laura, intentos de romper reglas 
|                            y transacciones
└── README.md
```

## Estructura de datos


| Tipo | Tablas |
| --- | --- |
| Entidades | subscriptions, subscribers, profiles, libraries, playlists, songs, albums, artists, countries |
| Tablas de unión | playlist_song, song_artist, song_album, library_song, library_album |

Las cardinalidades del diagrama están definidas por una restricción de esquema cada una:

| Cardinalidad | Restricción |
| --- | --- |
| Mínimo 1 (ej. todo suscriptor tiene una suscripción) | `NOT NULL` en la llave foránea |
| Máximo 1 en una relación 1 a 1 (ej. un suscriptor, un perfil) | `UNIQUE` en la llave foránea |
| Un par no se repite en una tabla de unión | PRIMARY KEY compuesta |
| Supuestos en base a lógica de negocio (precio ≥ 0, rol principal o feat., etc.) | `CHECK` |

## Supuestos

- Un suscriptor está en una sola suscripción a la vez.
- El precio y los anuncios dependen solo de la suscripción.
- Una canción no se repite dentro de una misma playlist, álbum o biblioteca.
- El orden de las canciones en la celda de una playlist es su posición.
- La duración de las canciones se guarda en segundos.
- Se usan llaves sustitutas (`subscriber_id`, `subscription_id`, `profile_id`, `library_id`) porque un correo o el nombre de una suscripción pueden cambiar. `email` y `subscriptions.name` son únicos.
- `subscriber_id`, `profile_id` y `library_id` se asignaron en el orden de la tabla D (ana = 1, luis = 2, marta = 3, diego = 4).
- Todo álbum lo publica exactamente un artista, como en el diagrama conceptual unificado.
- La foto del perfil es opcional (Marta no tiene).

### Casos agregados para testing

| Caso | Registro |
| --- | --- |
| Playlist vacía | Viaje (13) |
| Canción sin álbum | Calor de Agosto (108) |
| Suscripción sin suscriptores | Estudiantes (4), $15 al mes |
| Artista sin canciones ni álbumes | Noah Kahan (A11) |


## Variables de entorno

Las credenciales van en un archivo `.env` , se puede crear a partir de:

```bash
cp .env.example .env
```

| Variable | Qué es | Valor de ejemplo |
| --- | --- | --- |
| `POSTGRES_USER` | Usuario de PostgreSQL | `admin` |
| `POSTGRES_PASSWORD` | Contraseña de ese usuario | "contrasena123" |
| `POSTGRES_DB` | Base de datos que se crea | `spotify` |

## Inicializar PostgreSQL

Requisitos: Docker y Docker Compose. Los comandos se ejecutan en la carpeta del repositorio.

```bash
docker compose up -d
docker compose logs postgres | grep ERROR
```

## Ejecución de testing

```bash
docker compose exec postgres psql -U admin -d spotify -f /tests.sql
```

Se usan los valores de `POSTGRES_USER` y `POSTGRES_DB` de `.env` y cada prueba tiene un comentario con el resultado esperado.

- a) Responde preguntas de Laura sobre insights de los datos.
- b) Intentos de romper las restricciones de esquema, errores esperados.
- c) Registro y eliminación de un suscriptor con transacciones, evaluando casos exitosos y fallidos.

Para repetir las pruebas, se debe reiniciar el contenedor desde cero porque la sección c modifica datos. Se puede reiniciar utilizando:

```bash
docker compose down -v && docker compose up -d
```