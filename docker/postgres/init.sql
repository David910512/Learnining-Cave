-- =========================================================
-- INIT: Esquema compartido "core" (dueño: django_user)
-- Django administra/migra; Spring usa (R/W).
-- =========================================================

-- 1 Crear usuarios si no existen (se ejecuta como POSTGRES_USER, p.ej. "admin")
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'django_user') THEN
    CREATE USER django_user WITH PASSWORD 'django_pass';
  END IF;

  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'spring_user') THEN
    CREATE USER spring_user WITH PASSWORD 'spring_pass';
  END IF;
END$$;

-- 2 Esquema compartido y dueño
CREATE SCHEMA IF NOT EXISTS core AUTHORIZATION django_user;

-- Ambos pueden usar el esquema (entrar/buscar objetos)
GRANT USAGE ON SCHEMA core TO django_user, spring_user;

-- (OPCIONAL) Si algún día Spring también debe crear tablas:
-- GRANT CREATE ON SCHEMA core TO spring_user;

-- 3 Privilegios por defecto sobre LO QUE CREE django_user en "core"
--    (aplica a objetos futuros creados por django_user)
ALTER DEFAULT PRIVILEGES FOR ROLE django_user IN SCHEMA core
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO spring_user;

ALTER DEFAULT PRIVILEGES FOR ROLE django_user IN SCHEMA core
  GRANT USAGE, SELECT ON SEQUENCES TO spring_user;

-- 4) (Sugerido) Search path por defecto al conectarse
ALTER ROLE django_user SET search_path TO core, public;
ALTER ROLE spring_user SET search_path TO core, public;

-- 5) A partir de aquí creamos todo como django_user en "core"
SET ROLE django_user;
SET search_path TO core, public;

-- ============================
--    DDL DEL DOMINIO (TÚ)
-- ============================

-- ¡OJO! Estos DROP son útiles en DESARROLLO. Borran datos si existen.
DROP TABLE IF EXISTS respuestas CASCADE;
DROP TABLE IF EXISTS intentos CASCADE;
DROP TABLE IF EXISTS opciones CASCADE;
DROP TABLE IF EXISTS preguntas CASCADE;
DROP TABLE IF EXISTS quizzes CASCADE;
DROP TABLE IF EXISTS recursos CASCADE;
DROP TABLE IF EXISTS diapositivas CASCADE;
DROP TABLE IF EXISTS lecciones CASCADE;
DROP TABLE IF EXISTS matriculas CASCADE;
DROP TABLE IF EXISTS curso_profesores CASCADE;
DROP TABLE IF EXISTS cursos CASCADE;
DROP TABLE IF EXISTS tareas_ia CASCADE;
DROP TABLE IF EXISTS usuarios CASCADE;

DROP TYPE IF EXISTS rol_usuario_enum CASCADE;
DROP TYPE IF EXISTS estado_matricula_enum CASCADE;
DROP TYPE IF EXISTS tipo_recurso_enum CASCADE;

-- ---------- Tipos ENUM ----------
CREATE TYPE rol_usuario_enum AS ENUM ('estudiante','profesor','admin');
CREATE TYPE estado_matricula_enum AS ENUM ('activo','completado','retirado');
CREATE TYPE tipo_recurso_enum AS ENUM ('imagen','audio','video','archivo');

-- ---------- Tabla: usuarios ----------
CREATE TABLE usuarios (
  id_usuario       BIGSERIAL PRIMARY KEY,
  nombre_completo  TEXT        NOT NULL,
  correo           TEXT        NOT NULL UNIQUE,
  contrasena_hash  TEXT        NOT NULL,   -- sin acento para evitar problemas
  rol              rol_usuario_enum NOT NULL DEFAULT 'estudiante',
  fecha_creacion   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------- Tabla: cursos ----------
CREATE TABLE cursos (
  id_curso       BIGSERIAL PRIMARY KEY,
  codigo         TEXT UNIQUE,                      -- ej: INF101
  nombre         TEXT        NOT NULL,
  descripcion    TEXT,
  id_propietario BIGINT      NOT NULL REFERENCES usuarios(id_usuario) ON DELETE RESTRICT,
  fecha_creacion TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_cursos_propietario ON cursos(id_propietario);

-- ---------- Tabla puente: curso_profesores (muchos a muchos) ----------
CREATE TABLE curso_profesores (
  id_curso   BIGINT NOT NULL REFERENCES cursos(id_curso)     ON DELETE CASCADE,
  id_usuario BIGINT NOT NULL REFERENCES usuarios(id_usuario) ON DELETE CASCADE,
  PRIMARY KEY (id_curso, id_usuario)
);

-- ---------- Tabla: matriculas (alumno ↔ curso) ----------
CREATE TABLE matriculas (
  id_matricula     BIGSERIAL PRIMARY KEY,
  id_curso         BIGINT NOT NULL REFERENCES cursos(id_curso)      ON DELETE CASCADE,
  id_estudiante    BIGINT NOT NULL REFERENCES usuarios(id_usuario)  ON DELETE CASCADE,
  estado           estado_matricula_enum NOT NULL DEFAULT 'activo',
  fecha_matricula  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (id_curso, id_estudiante)
);
CREATE INDEX idx_matriculas_curso ON matriculas(id_curso);
CREATE INDEX idx_matriculas_estudiante ON matriculas(id_estudiante);

-- ---------- Tabla: lecciones ----------
CREATE TABLE lecciones (
  id_leccion  BIGSERIAL PRIMARY KEY,
  id_curso    BIGINT NOT NULL REFERENCES cursos(id_curso) ON DELETE CASCADE,
  titulo      TEXT   NOT NULL,
  resumen     TEXT,
  url_ppt     TEXT,            -- ruta/URL a PPT generado
  url_video   TEXT,            -- ruta/URL a video generado
  numero      INT    NOT NULL DEFAULT 1,  -- orden dentro del curso
  fecha_creacion TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_lecciones_curso_numero ON lecciones(id_curso, numero);

-- ---------- Tabla: diapositivas ----------
CREATE TABLE diapositivas (
  id_diapositiva BIGSERIAL PRIMARY KEY,
  id_leccion     BIGINT NOT NULL REFERENCES lecciones(id_leccion) ON DELETE CASCADE,
  numero         INT    NOT NULL,  -- orden dentro de la lección
  titulo         TEXT,
  contenido      JSONB             -- lista de bullets / estructura de la slide
);
CREATE UNIQUE INDEX ux_diapositivas_leccion_numero ON diapositivas(id_leccion, numero);

-- ---------- Tabla: recursos (assets multimedia) ----------
CREATE TABLE recursos (
  id_recurso     BIGSERIAL PRIMARY KEY,
  id_leccion     BIGINT NOT NULL REFERENCES lecciones(id_leccion)     ON DELETE CASCADE,
  id_diapositiva BIGINT     REFERENCES diapositivas(id_diapositiva)   ON DELETE CASCADE,
  tipo           tipo_recurso_enum NOT NULL,
  url            TEXT NOT NULL,
  metadata       JSONB,
  fecha_creacion TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_recursos_leccion ON recursos(id_leccion);
CREATE INDEX idx_recursos_diapositiva ON recursos(id_diapositiva);

-- ---------- Tabla: quizzes (1 por lección) ----------
CREATE TABLE quizzes (
  id_quiz     BIGSERIAL PRIMARY KEY,
  id_leccion  BIGINT UNIQUE NOT NULL REFERENCES lecciones(id_leccion) ON DELETE CASCADE,
  titulo      TEXT,
  ajustes     JSONB,  -- ej: { "tiempo_seg": 600, "intentos_max": 2 }
  fecha_creacion TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------- Tabla: preguntas ----------
CREATE TABLE preguntas (
  id_pregunta  BIGSERIAL PRIMARY KEY,
  id_quiz      BIGINT NOT NULL REFERENCES quizzes(id_quiz) ON DELETE CASCADE,
  numero       INT    NOT NULL,   -- orden
  enunciado    TEXT   NOT NULL,
  explicacion  TEXT,               -- feedback general
  puntaje      NUMERIC(6,2) NOT NULL DEFAULT 1.0
);
CREATE UNIQUE INDEX ux_preguntas_quiz_numero ON preguntas(id_quiz, numero);

-- ---------- Tabla: opciones ----------
CREATE TABLE opciones (
  id_opcion    BIGSERIAL PRIMARY KEY,
  id_pregunta  BIGINT NOT NULL REFERENCES preguntas(id_pregunta) ON DELETE CASCADE,
  numero       INT    NOT NULL,   -- orden A,B,C... (1,2,3,...)
  texto        TEXT   NOT NULL,
  es_correcta  BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE UNIQUE INDEX ux_opciones_pregunta_numero ON opciones(id_pregunta, numero);

-- ---------- Tabla: intentos (de estudiantes en un quiz) ----------
CREATE TABLE intentos (
  id_intento     BIGSERIAL PRIMARY KEY,
  id_quiz        BIGINT NOT NULL REFERENCES quizzes(id_quiz)     ON DELETE CASCADE,
  id_estudiante  BIGINT NOT NULL REFERENCES usuarios(id_usuario) ON DELETE CASCADE,
  puntaje        NUMERIC(6,2),
  fecha_inicio   TIMESTAMPTZ NOT NULL DEFAULT now(),
  fecha_fin      TIMESTAMPTZ
);
CREATE INDEX idx_intentos_quiz_estudiante ON intentos(id_quiz, id_estudiante);

-- ---------- Tabla: respuestas (de un intento) ----------
CREATE TABLE respuestas (
  id_respuesta       BIGSERIAL PRIMARY KEY,
  id_intento         BIGINT NOT NULL REFERENCES intentos(id_intento)    ON DELETE CASCADE,
  id_pregunta        BIGINT NOT NULL REFERENCES preguntas(id_pregunta)  ON DELETE CASCADE,
  id_opcion          BIGINT     REFERENCES opciones(id_opcion)          ON DELETE SET NULL,
  es_correcta        BOOLEAN,
  retroalimentacion  TEXT,
  UNIQUE (id_intento, id_pregunta)  -- una respuesta por pregunta en el intento
);
CREATE INDEX idx_respuestas_intento ON respuestas(id_intento);

-- ---------- Tabla: tareas_ia (trazabilidad) ----------
CREATE TABLE tareas_ia (
  id_tarea       BIGSERIAL PRIMARY KEY,
  id_leccion     BIGINT REFERENCES lecciones(id_leccion) ON DELETE CASCADE,
  tipo           TEXT   NOT NULL,    -- 'generar_diapositivas' | 'generar_quiz' | 'generar_video'
  prompt         TEXT,
  modelo         TEXT,
  referencia     TEXT,               -- archivo/URL/ID del recurso generado
  estado         TEXT   NOT NULL DEFAULT 'pendiente',  -- 'pendiente' | 'ejecutando' | 'completado' | 'fallido'
  costo_usd      NUMERIC(10,4),
  fecha_creacion TIMESTAMPTZ NOT NULL DEFAULT now(),
  fecha_fin      TIMESTAMPTZ
);
CREATE INDEX idx_tareas_ia_leccion ON tareas_ia(id_leccion);

-- 6) (Seguridad) Asegura permisos sobre lo que ACABAMOS de crear (belt & suspenders)
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES     IN SCHEMA core TO spring_user;
GRANT USAGE, SELECT               ON ALL SEQUENCES IN SCHEMA core TO spring_user;

-- 7) Volver al rol original (admin del contenedor)
RESET ROLE;
