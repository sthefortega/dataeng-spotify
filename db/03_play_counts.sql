-- =====================================================================
-- 03_play_counts.sql · Migración: conteos de reproducciones
-- Agrega las dos tablas que el processor mantiene a partir de los mensajes
-- de Kafka. Los mensajes no se guardan aquí: solo los conteos.
--
-- Se puede ejecutar dos veces sin error (IF NOT EXISTS).
-- =====================================================================

-- Reproducciones válidas de cada suscriptor por canción, desde siempre.
-- Responde: las 20 canciones más escuchadas de un suscriptor.
CREATE TABLE IF NOT EXISTS subscriber_song_play (
    subscriber_id integer NOT NULL REFERENCES subscribers (subscriber_id),
    song_id       integer NOT NULL REFERENCES songs (song_id),
    num_rep       integer NOT NULL CHECK (num_rep > 0),   -- solo existe la fila si hay al menos 1
    PRIMARY KEY (subscriber_id, song_id)
);

-- Reproducciones válidas de cada canción por día (UTC).
-- Responde: el top 100 semanal.
CREATE TABLE IF NOT EXISTS song_daily_play (
    song_id   integer NOT NULL REFERENCES songs (song_id),
    play_date date    NOT NULL,                           -- día en UTC en que ocurrió la reproducción
    num_rep   integer NOT NULL CHECK (num_rep > 0),
    PRIMARY KEY (song_id, play_date)
);

-- El top semanal filtra por rango de fechas; la PK empieza por song_id y no
-- ayuda a esa búsqueda, así que se agrega un índice por play_date.
CREATE INDEX IF NOT EXISTS song_daily_play_play_date_idx ON song_daily_play (play_date);
