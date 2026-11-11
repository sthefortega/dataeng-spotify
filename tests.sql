
-- Pruebas de la base de datos de Spotify

-- Configuración para mejorar la visualización de resultados
\pset pager off
\x auto

-- a) Preguntas a responder de Laura

\echo '¿Qué canciones tiene la playlist 10, en orden, y quiénes son sus artistas?'

SELECT ps.position AS posicion,
       s.title     AS cancion,
       string_agg(a.name || CASE WHEN sa.role = 'feat.' THEN ' (feat.)' ELSE '' END,
                  ', ' ORDER BY sa.role = 'feat.', a.name) AS artistas
FROM playlist_song ps
JOIN songs s        ON s.song_id = ps.song_id
JOIN song_artist sa ON sa.song_id = s.song_id
JOIN artists a      ON a.artist_id = sa.artist_id
WHERE ps.playlist_id = 10
GROUP BY ps.position, s.title
ORDER BY ps.position;

\echo
\echo '¿Cuántos suscriptores tiene cada suscripción?'

SELECT su.name AS suscripcion,
       COUNT(sb.subscriber_id) AS suscriptores
FROM subscriptions su
LEFT JOIN subscribers sb ON sb.subscription_id = su.subscription_id
GROUP BY su.subscription_id, su.name
ORDER BY suscriptores DESC, su.name;

\echo
\echo '¿Qué canciones no están en ningún álbum?'

SELECT s.song_id, s.title AS cancion
FROM songs s
LEFT JOIN song_album sa ON sa.song_id = s.song_id
WHERE sa.song_id IS NULL;

\echo
\echo '¿Qué tiene guardado cada suscriptor en su biblioteca, canciones y álbumes?'
SELECT sb.email,
       COALESCE(g.tipo, '—')                    AS tipo,
       COALESCE(g.titulo, '(biblioteca vacía)') AS guardado
FROM subscribers sb
JOIN libraries l ON l.subscriber_id = sb.subscriber_id
LEFT JOIN (
    SELECT ls.library_id, 'canción' AS tipo, s.title AS titulo
    FROM library_song ls
    JOIN songs s ON s.song_id = ls.song_id
    UNION ALL
    SELECT la.library_id, 'álbum' AS tipo, al.title AS titulo
    FROM library_album la
    JOIN albums al ON al.album_id = la.album_id
) g ON g.library_id = l.library_id
ORDER BY sb.email, g.tipo, g.titulo;

-- ¿Cuál es la canción más escuchada?
-- En la Tarea 3 no se podía responder porque no había datos de reproducciones. Ahora sí:
-- el processor cuenta las reproducciones válidas que llegan por Kafka.
-- Se usa song_daily_play, que guarda todas las reproducciones válidas por canción y día.
-- "Más escuchada" = la que tiene más reproducciones válidas desde siempre.
-- Esperado: 1 fila (o varias, si hay empate en el primer lugar).
\echo
\echo '¿Cuál es la canción más escuchada?'

WITH totales AS (
    SELECT song_id, SUM(num_rep) AS reproducciones
    FROM song_daily_play
    GROUP BY song_id
)
SELECT s.song_id, s.title AS cancion, t.reproducciones
FROM totales t
JOIN songs s ON s.song_id = t.song_id
WHERE t.reproducciones = (SELECT MAX(reproducciones) FROM totales)
ORDER BY s.song_id;

-- Top 100 semanal (regla 4): las 100 canciones con más reproducciones válidas de la
-- última semana completa, de lunes a domingo, en UTC (regla 3). La semana en curso no cuenta.
-- date_trunc('week', ...) regresa el lunes de la semana actual; la semana anterior va de
-- ese lunes menos 7 días al domingo anterior (ese lunes menos 1 día).
-- Esperado: primero, las fechas de la semana; después, hasta 100 canciones ordenadas
-- de mayor a menor (con este catálogo, a lo más 8).
\echo
\echo 'Top 100 semanal: semana evaluada'

SELECT (date_trunc('week', now() AT TIME ZONE 'UTC') - interval '7 days')::date AS lunes,
       (date_trunc('week', now() AT TIME ZONE 'UTC') - interval '1 day')::date  AS domingo;

\echo 'Top 100 semanal'

SELECT RANK() OVER (ORDER BY SUM(d.num_rep) DESC) AS lugar,
       s.song_id,
       s.title         AS cancion,
       SUM(d.num_rep)  AS reproducciones
FROM song_daily_play d
JOIN songs s ON s.song_id = d.song_id
WHERE d.play_date BETWEEN (date_trunc('week', now() AT TIME ZONE 'UTC') - interval '7 days')::date
                      AND (date_trunc('week', now() AT TIME ZONE 'UTC') - interval '1 day')::date
GROUP BY s.song_id, s.title
ORDER BY reproducciones DESC, s.song_id
LIMIT 100;

-- Las 20 canciones más escuchadas de un suscriptor (regla 5), desde siempre.
-- Se usa ana (subscriber_id 1), que no se elimina en la parte c.
-- Esperado: hasta 20 canciones de ana, ordenadas de mayor a menor (con este catálogo, a lo más 8).
\echo
\echo 'Las 20 canciones más escuchadas de ana@mail.com'

SELECT RANK() OVER (ORDER BY ssp.num_rep DESC) AS lugar,
       s.song_id,
       s.title       AS cancion,
       ssp.num_rep   AS reproducciones
FROM subscriber_song_play ssp
JOIN songs s ON s.song_id = ssp.song_id
WHERE ssp.subscriber_id = 1
ORDER BY ssp.num_rep DESC, s.song_id
LIMIT 20;



-- b) Romper las reglas


\echo
\echo 'Pruebas de ruptura de reglas programadas, errores esperados.'
\echo

-- PRIMARY KEY: no puede haber dos canciones con el mismo song_id.
-- Esperado: ERROR por llave duplicada.
\echo 'TEST 1: Insertar PK duplicada: canción 101'
INSERT INTO songs (song_id, title, duration_seconds, genre)
VALUES (101, 'Canción duplicada', 200, 'Pop');

-- PRIMARY KEY compuesta: una canción no se puede repetir en una sola playlist.
-- Esperado: ERROR por llave duplicada.
\echo
\echo 'TEST 2: Insertar PK compuesta duplicada: canción 101 en playlist 10'
INSERT INTO playlist_song (playlist_id, song_id, position, added_at)
VALUES (10, 101, 4, '2026-07-01');

-- NOT NULL: todo suscriptor está en una única suscripción siempre
-- Esperado: ERROR por valor nulo en subscription_id.
\echo
\echo 'TEST 3: Insertar suscriptor sin suscripción'
INSERT INTO subscribers (subscriber_id, email, registered_at, subscription_id)
VALUES (7, 'nuevo@mail.com', '2026-07-01', NULL);

-- NOT NULL: todos los álbumes los publica un artista como mínimo.
-- Esperado: ERROR por valor nulo en artist_id.
\echo
\echo 'TEST 4: Insertar álbum sin artista'
INSERT INTO albums (album_id, title, release_year, cover_url, artist_id)
VALUES (207, 'Álbum sin artista', 2025, 'sin_artista.jpg', NULL);

-- UNIQUE: dos suscriptores no pueden tener el mismo correo.
-- Esperado: ERROR por llave duplicada.
\echo
\echo 'TEST 5: Insertar suscriptor con un correo ya registrado (duplicado)'
INSERT INTO subscribers (subscriber_id, email, registered_at, subscription_id)
VALUES (7, 'ana@mail.com', '2026-07-01', 1);

-- UNIQUE: un suscriptor tiene un único perfil como máximo.
-- Esperado: ERROR por llave duplicada.
\echo
\echo 'TEST 6: Insertar perfil duplicado (profile_id) para el suscriptor 1'
INSERT INTO profiles (profile_id, subscriber_id, display_name, photo_url, country_code)
VALUES (7, 1, 'ana_otra', NULL, 'MX');

-- UNIQUE: dos canciones no pueden tener la misma posición en una playlist.
-- Esperado: ERROR por llave duplicada.
\echo
\echo 'TEST 7: Insertar posición duplicada en playlist'
INSERT INTO playlist_song (playlist_id, song_id, position, added_at)
VALUES (10, 104, 1, '2026-07-01');

-- UNIQUE: un álbum no repite número de pista.
-- Esperado: ERROR por llave duplicada.
\echo
\echo 'TEST 8: Insertar número de pista duplicado en álbum'
INSERT INTO song_album (song_id, album_id, track_number)
VALUES (108, 206, 12);

-- FOREIGN KEY: todas las playlist son de un suscriptor registrado.
-- Esperado: ERROR por no tener llave foránea (id de suscriptor) válida.
\echo
\echo 'TEST 9: Insertar playlist sin suscriptor válido/existente'
INSERT INTO playlists (playlist_id, name, created_at, subscriber_id)
VALUES (15, 'Nueva', '2026-07-01', 99);

-- FOREIGN KEY al actualizar: el id de artista debe estar ligado a un artista que existe.
-- Esperado: ERROR por llave foránea inválida.
\echo
\echo 'TEST 10: Actualizar artista con id no existente'
UPDATE song_artist SET artist_id = 'A99' WHERE song_id = 104;

-- FOREIGN KEY al borrar: no se puede borrar un artista que tiene canciones y álbumes.
-- Esperado: ERROR por llave foránea ligada a datos existentes.
\echo
\echo 'TEST 11: Borrar artista con canciones y álbumes disponibles'
DELETE FROM artists WHERE artist_id = 'A2';

-- CHECK: el rol de un artista en una canción solo puede ser 'principal' o 'feat.'.
-- Esperado: ERROR por ingresar datos fuera de scope.
\echo
\echo 'TEST 12: Insertar rol de artista inválido'
INSERT INTO song_artist (song_id, artist_id, role)
VALUES (104, 'A1', 'productor');

-- CHECK: una canción no puede durar 0 segundos.
-- Esperado: ERROR por restricción de tiempo.
\echo
\echo 'TEST 13: Actualizar duración de canción a 0 segundos'
UPDATE songs SET duration_seconds = 0 WHERE song_id = 101;

-- CHECK: una suscripción no puede tener precio negativo.
-- Esperado: ERROR por restricción de precio.
\echo
\echo 'TEST 14: Actualizar precio de suscripción a negativo'
UPDATE subscriptions SET monthly_price = -10 WHERE subscription_id = 1;

-- CHECK: un conteo de reproducciones no puede ser 0 ni negativo; una fila solo existe
-- si hay al menos una reproducción válida.
-- Esperado: ERROR por violar la restricción check.
\echo
\echo 'TEST 15: Insertar un conteo de reproducciones en 0'
INSERT INTO song_daily_play (song_id, play_date, num_rep)
VALUES (101, '2026-01-01', 0);

-- FOREIGN KEY: un conteo debe ser de un suscriptor y una canción que existen.
-- Esperado: ERROR por llave foránea inválida.
\echo
\echo 'TEST 16: Insertar un conteo de un suscriptor que no existe'
INSERT INTO subscriber_song_play (subscriber_id, song_id, num_rep)
VALUES (99, 101, 1);



-- c) Registro y eliminación de un suscriptor, con transacciones

-- c.1) Registro exitoso

\echo
\echo 'c.1) Registro exitoso de sthef@mail.com'

BEGIN;
INSERT INTO subscribers (subscriber_id, email, registered_at, subscription_id)
VALUES (5, 'sthef@mail.com', '2026-11-01', 1);
INSERT INTO profiles (profile_id, subscriber_id, display_name, photo_url, country_code)
VALUES (5, 5, 'sthef', 's5.jpg', 'MX');
INSERT INTO libraries (library_id, subscriber_id)
VALUES (5, 5);
COMMIT;

-- Esperado: 1 fila con sthef@mail.com, el perfil (sthef) y su biblioteca (5).
SELECT sb.email, p.display_name, l.library_id
FROM subscribers sb
JOIN profiles p  ON p.subscriber_id = sb.subscriber_id
JOIN libraries l ON l.subscriber_id = sb.subscriber_id
WHERE sb.email = 'sthef@mail.com';


-- c.2) Falla de registro a medias

\echo
\echo '=== c.2) Registro de manuel@mail.com que falla a medio camino'

-- Antes. Esperado: 0 (no existe).
SELECT COUNT(*) AS manuel_antes FROM subscribers WHERE email = 'manuel@mail.com';

BEGIN;
INSERT INTO subscribers (subscriber_id, email, registered_at, subscription_id)
VALUES (6, 'manuel@mail.com', '2026-11-01', 1);
INSERT INTO profiles (profile_id, subscriber_id, display_name, photo_url, country_code)
VALUES (6, 6, 'manuel', NULL, 'PG');                         -- PG falla porque no existe en el catálogo de países
INSERT INTO libraries (library_id, subscriber_id)
VALUES (6, 6);
COMMIT;

-- Después. Esperado: 0 en las tres columnas.

SELECT (SELECT COUNT(*) FROM subscribers WHERE email = 'manuel@mail.com') AS suscriptor,
       (SELECT COUNT(*) FROM profiles    WHERE subscriber_id = 6)       AS perfil,
       (SELECT COUNT(*) FROM libraries   WHERE subscriber_id = 6)       AS biblioteca;

-- c.3) Eliminación exitosa
-- No se usa ON DELETE CASCADE: cada dependencia del suscriptor se borra de forma explícita,
-- en orden, dentro de una sola transacción.
-- Desde la Tarea 4, luis también tiene conteos en subscriber_song_play, que apuntan a él
-- con una llave foránea: hay que borrarlos antes que al suscriptor, o el DELETE falla.
--
-- ¿Cambia el top semanal al eliminar a un suscriptor? NO.
-- El top semanal se calcula con song_daily_play, que guarda reproducciones por canción y
-- día, sin saber de qué suscriptor son: no hay nada de luis que borrar ahí. Las
-- reproducciones de luis sí ocurrieron, así que siguen contando en el top semanal y en
-- "la canción más escuchada". Lo que sí desaparece son sus 20 más escuchadas, porque
-- eran suyas (subscriber_song_play).
-- Consecuencias:
--   * Después de esta eliminación, el total de subscriber_song_play ya no es igual al de
--     song_daily_play, y verify.py ya no muestra OK: por eso se ejecuta antes de tests.sql.
--   * Si siguen llegando mensajes de luis por Kafka, el processor los descarta como
--     "IDs inexistentes", porque luis ya no existe.

\echo
\echo 'c.3) Eliminación exitosa de luis@mail.com'

-- Antes. Esperado: 1 | 1 | 1 | 1 | 2 | 2 | 5 | N (las canciones de luis con conteos; depende de
-- las reproducciones simuladas) y el catálogo con 8 canciones, 6 álbumes y 11 artistas.
SELECT (SELECT COUNT(*) FROM subscribers   WHERE subscriber_id = 2)           AS suscriptor,
       (SELECT COUNT(*) FROM profiles      WHERE subscriber_id = 2)           AS perfil,
       (SELECT COUNT(*) FROM libraries     WHERE subscriber_id = 2)           AS biblioteca,
       (SELECT COUNT(*) FROM library_song  WHERE library_id = 2)              AS canciones_guardadas,
       (SELECT COUNT(*) FROM library_album WHERE library_id = 2)              AS albumes_guardados,
       (SELECT COUNT(*) FROM playlists     WHERE subscriber_id = 2)           AS playlists,
       (SELECT COUNT(*) FROM playlist_song WHERE playlist_id IN (12, 14))     AS canciones_en_playlists,
       (SELECT COUNT(*) FROM subscriber_song_play WHERE subscriber_id = 2)    AS conteos_por_cancion,
       (SELECT COUNT(*) FROM songs)   AS catalogo_canciones,
       (SELECT COUNT(*) FROM albums)  AS catalogo_albumes,
       (SELECT COUNT(*) FROM artists) AS catalogo_artistas;

-- Top semanal antes de eliminar (reproducciones por canción de la última semana completa).
\echo 'Top semanal ANTES de eliminar a luis'
SELECT d.song_id, SUM(d.num_rep) AS reproducciones_semana
FROM song_daily_play d
WHERE d.play_date BETWEEN (date_trunc('week', now() AT TIME ZONE 'UTC') - interval '7 days')::date
                      AND (date_trunc('week', now() AT TIME ZONE 'UTC') - interval '1 day')::date
GROUP BY d.song_id
ORDER BY reproducciones_semana DESC, d.song_id;

BEGIN;
-- Las canciones de sus playlists
DELETE FROM playlist_song
WHERE playlist_id IN (SELECT playlist_id FROM playlists WHERE subscriber_id = 2);
-- Sus playlists
DELETE FROM playlists WHERE subscriber_id = 2;
-- Los guardados en su biblioteca
DELETE FROM library_song
WHERE library_id IN (SELECT library_id FROM libraries WHERE subscriber_id = 2);
DELETE FROM library_album
WHERE library_id IN (SELECT library_id FROM libraries WHERE subscriber_id = 2);
-- Sus conteos de reproducciones por canción (Tarea 4)
DELETE FROM subscriber_song_play WHERE subscriber_id = 2;
-- Su biblioteca y su perfil
DELETE FROM libraries WHERE subscriber_id = 2;
DELETE FROM profiles  WHERE subscriber_id = 2;
-- El suscriptor
DELETE FROM subscribers WHERE subscriber_id = 2;
COMMIT;

-- Después. Esperado: 0 en las ocho primeras columnas y el catálogo igual (8 canciones, 6 álbumes, 11 artistas).
SELECT (SELECT COUNT(*) FROM subscribers   WHERE subscriber_id = 2)           AS suscriptor,
       (SELECT COUNT(*) FROM profiles      WHERE subscriber_id = 2)           AS perfil,
       (SELECT COUNT(*) FROM libraries     WHERE subscriber_id = 2)           AS biblioteca,
       (SELECT COUNT(*) FROM library_song  WHERE library_id = 2)              AS canciones_guardadas,
       (SELECT COUNT(*) FROM library_album WHERE library_id = 2)              AS albumes_guardados,
       (SELECT COUNT(*) FROM playlists     WHERE subscriber_id = 2)           AS playlists,
       (SELECT COUNT(*) FROM playlist_song WHERE playlist_id IN (12, 14))     AS canciones_en_playlists,
       (SELECT COUNT(*) FROM subscriber_song_play WHERE subscriber_id = 2)    AS conteos_por_cancion,
       (SELECT COUNT(*) FROM songs)   AS catalogo_canciones,
       (SELECT COUNT(*) FROM albums)  AS catalogo_albumes,
       (SELECT COUNT(*) FROM artists) AS catalogo_artistas;

-- Top semanal después de eliminar. Esperado: exactamente igual que antes.
\echo 'Top semanal DESPUÉS de eliminar a luis (debe ser igual)'
SELECT d.song_id, SUM(d.num_rep) AS reproducciones_semana
FROM song_daily_play d
WHERE d.play_date BETWEEN (date_trunc('week', now() AT TIME ZONE 'UTC') - interval '7 days')::date
                      AND (date_trunc('week', now() AT TIME ZONE 'UTC') - interval '1 day')::date
GROUP BY d.song_id
ORDER BY reproducciones_semana DESC, d.song_id;

-- ---------------------------------------------------------------------
-- c.4) Falla: Eliminación a medias

\echo
\echo '=== c.4) Eliminación de ana@mail.com que falla a medio camino'

-- Antes. Esperado: 1 | 1 | 1 | 2 | 1 | 2 | 5 | N (las canciones de ana con conteos)
SELECT (SELECT COUNT(*) FROM subscribers   WHERE subscriber_id = 1)           AS suscriptor,
       (SELECT COUNT(*) FROM profiles      WHERE subscriber_id = 1)           AS perfil,
       (SELECT COUNT(*) FROM libraries     WHERE subscriber_id = 1)           AS biblioteca,
       (SELECT COUNT(*) FROM library_song  WHERE library_id = 1)              AS canciones_guardadas,
       (SELECT COUNT(*) FROM library_album WHERE library_id = 1)              AS albumes_guardados,
       (SELECT COUNT(*) FROM playlists     WHERE subscriber_id = 1)           AS playlists,
       (SELECT COUNT(*) FROM playlist_song WHERE playlist_id IN (10, 11))     AS canciones_en_playlists,
       (SELECT COUNT(*) FROM subscriber_song_play WHERE subscriber_id = 1)    AS conteos_por_cancion;

BEGIN;
DELETE FROM library_song
WHERE library_id IN (SELECT library_id FROM libraries WHERE subscriber_id = 1);
DELETE FROM library_album
WHERE library_id IN (SELECT library_id FROM libraries WHERE subscriber_id = 1);
DELETE FROM subscriber_song_play WHERE subscriber_id = 1;   -- funciona: borra sus conteos
-- Intencionalmente no se borraron las canciones de playlist_song para provocar el error
DELETE FROM playlists WHERE subscriber_id = 1;     -- Error por playlist_song que todavía está ligada a ellas
DELETE FROM libraries WHERE subscriber_id = 1;
DELETE FROM profiles  WHERE subscriber_id = 1;
DELETE FROM subscribers WHERE subscriber_id = 1;
COMMIT;

-- Después. Esperado: lo mismo que antes, incluido N: sus conteos, que sí se habían
-- borrado dentro de la transacción, regresaron con el ROLLBACK.
SELECT (SELECT COUNT(*) FROM subscribers   WHERE subscriber_id = 1)           AS suscriptor,
       (SELECT COUNT(*) FROM profiles      WHERE subscriber_id = 1)           AS perfil,
       (SELECT COUNT(*) FROM libraries     WHERE subscriber_id = 1)           AS biblioteca,
       (SELECT COUNT(*) FROM library_song  WHERE library_id = 1)              AS canciones_guardadas,
       (SELECT COUNT(*) FROM library_album WHERE library_id = 1)              AS albumes_guardados,
       (SELECT COUNT(*) FROM playlists     WHERE subscriber_id = 1)           AS playlists,
       (SELECT COUNT(*) FROM playlist_song WHERE playlist_id IN (10, 11))     AS canciones_en_playlists,
       (SELECT COUNT(*) FROM subscriber_song_play WHERE subscriber_id = 1)    AS conteos_por_cancion;
