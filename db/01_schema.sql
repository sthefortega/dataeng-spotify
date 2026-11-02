
-- Estructura de base de datos de Spotify normalizada a 3FN

CREATE TABLE countries (
    country_code char(2)     PRIMARY KEY,   -- ej. "MX"
    name         varchar(60) NOT NULL UNIQUE -- ej. "Mexico"
);

CREATE TABLE subscriptions (
    subscription_id integer      PRIMARY KEY,
    name            varchar(30)  NOT NULL UNIQUE,
    monthly_price   numeric(8,2) NOT NULL CHECK (monthly_price >= 0),
    has_ads         boolean      NOT NULL
);


CREATE TABLE subscribers (
    subscriber_id   integer      PRIMARY KEY,
    email           varchar(100) NOT NULL UNIQUE,
    registered_at   date         NOT NULL,
    subscription_id integer      NOT NULL REFERENCES subscriptions (subscription_id)
);

CREATE TABLE profiles (
    profile_id    integer      PRIMARY KEY,
    subscriber_id integer      NOT NULL UNIQUE REFERENCES subscribers (subscriber_id),
    display_name  varchar(50)  NOT NULL,
    photo_url     varchar(255),
    country_code  char(2)      NOT NULL REFERENCES countries (country_code)
);

CREATE TABLE libraries (
    library_id    integer PRIMARY KEY,
    subscriber_id integer NOT NULL UNIQUE REFERENCES subscribers (subscriber_id)
);


CREATE TABLE artists (
    artist_id    varchar(5)   PRIMARY KEY,
    name         varchar(100) NOT NULL,
    country_code char(2)      NOT NULL REFERENCES countries (country_code)
);


CREATE TABLE albums (
    album_id     integer      PRIMARY KEY,
    title        varchar(150) NOT NULL,
    release_year smallint     NOT NULL CHECK (release_year BETWEEN 1900 AND 2100),
    cover_url    varchar(255) NOT NULL,
    artist_id    varchar(5)   NOT NULL REFERENCES artists (artist_id)
);


CREATE TABLE songs (
    song_id          integer      PRIMARY KEY,
    title            varchar(150) NOT NULL,
    duration_seconds integer      NOT NULL CHECK (duration_seconds > 0),
    genre            varchar(50)  NOT NULL
);


CREATE TABLE playlists (
    playlist_id   integer      PRIMARY KEY,
    name          varchar(100) NOT NULL,
    created_at    date         NOT NULL,
    subscriber_id integer      NOT NULL REFERENCES subscribers (subscriber_id)
);


CREATE TABLE playlist_song (
    playlist_id integer  NOT NULL REFERENCES playlists (playlist_id),
    song_id     integer  NOT NULL REFERENCES songs (song_id),
    position    smallint NOT NULL CHECK (position > 0),
    added_at    date     NOT NULL,
    PRIMARY KEY (playlist_id, song_id),
    UNIQUE (playlist_id, position)
);


CREATE TABLE song_artist (
    song_id   integer     NOT NULL REFERENCES songs (song_id),
    artist_id varchar(5)  NOT NULL REFERENCES artists (artist_id),
    role      varchar(10) NOT NULL CHECK (role IN ('principal', 'feat.')),
    PRIMARY KEY (song_id, artist_id)
);


CREATE TABLE song_album (
    song_id      integer  NOT NULL REFERENCES songs (song_id),
    album_id     integer  NOT NULL REFERENCES albums (album_id),
    track_number smallint NOT NULL CHECK (track_number > 0),
    PRIMARY KEY (song_id, album_id),
    UNIQUE (album_id, track_number)
);


CREATE TABLE library_song (
    library_id integer NOT NULL REFERENCES libraries (library_id),
    song_id    integer NOT NULL REFERENCES songs (song_id),
    PRIMARY KEY (library_id, song_id)
);


CREATE TABLE library_album (
    library_id integer NOT NULL REFERENCES libraries (library_id),
    album_id   integer NOT NULL REFERENCES albums (album_id),
    PRIMARY KEY (library_id, album_id)
);
