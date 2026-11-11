-- =====================================================================
-- 04_ingestion_checkpoint.sql · Migración: marcador de avance del processor
--
-- Guarda, por cada archivo del crudo, hasta qué byte ya lo procesó el processor.
-- No guarda ningún mensaje: solo una posición.
--
-- Por qué en PostgreSQL y no en un archivo: el processor actualiza esta tabla en la
-- misma transacción que los conteos. Así los conteos y el marcador avanzan juntos o no
-- avanzan: si el processor se cae a la mitad, la siguiente corrida retoma desde el último
-- COMMIT y ninguna reproducción se cuenta dos veces ni se pierde.
--
-- Se puede ejecutar dos veces sin error (IF NOT EXISTS).
-- =====================================================================

CREATE TABLE IF NOT EXISTS ingestion_checkpoint (
    raw_file    varchar(200) PRIMARY KEY,                       -- nombre del archivo del crudo
    byte_offset bigint       NOT NULL CHECK (byte_offset >= 0), -- bytes ya procesados
    updated_at  timestamptz  NOT NULL DEFAULT now()             -- última corrida que lo avanzó
);
