--elaborado por Ruan Lopez Tai Ping Alejandra - 24170724
DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;

CREATE TABLE profesor (
    id_profesor  SERIAL PRIMARY KEY,
    clave        VARCHAR(10) NOT NULL UNIQUE,
    nombre       VARCHAR(30) NOT NULL
);

CREATE TABLE materia (
    id_materia  SERIAL PRIMARY KEY,
    clave       CHAR(1)     NOT NULL UNIQUE CHECK (clave BETWEEN 'A' AND 'Z'),
    nombre      VARCHAR(30) NOT NULL,
    semestre    INT NOT NULL CHECK (semestre BETWEEN 1 AND 8)
);

CREATE TABLE preferencia (
    id_profesor  INT NOT NULL REFERENCES profesor ON DELETE CASCADE,
    id_materia   INT NOT NULL REFERENCES materia  ON DELETE CASCADE,
    prioridad    INT NOT NULL CHECK (prioridad BETWEEN 1 AND 4),
    PRIMARY KEY (id_profesor, id_materia),
    UNIQUE (id_profesor, prioridad) DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE disponibilidad (
    id_profesor  INT NOT NULL REFERENCES profesor ON DELETE CASCADE,
    hora         INT NOT NULL CHECK (hora BETWEEN 7 AND 21),
    PRIMARY KEY (id_profesor, hora)
);

CREATE TABLE paquete (
    id_paquete  SERIAL PRIMARY KEY,
    semestre    INT NOT NULL CHECK (semestre BETWEEN 1 AND 8),
    grupo       CHAR(1) NOT NULL,
    UNIQUE (semestre, grupo)
);

CREATE TABLE opcion (
    id_profesor  INT NOT NULL REFERENCES profesor ON DELETE CASCADE,
    hora         INT NOT NULL,
    id_materia   INT NOT NULL REFERENCES materia ON DELETE CASCADE,
    prioridad    INT NOT NULL,
    estado       VARCHAR(12) NOT NULL DEFAULT 'pendiente'
                 CHECK (estado IN ('pendiente', 'asignada', 'descartada')),
    PRIMARY KEY (id_profesor, hora, id_materia)
);

CREATE TABLE clase (
    id_clase     SERIAL PRIMARY KEY,
    id_paquete   INT NOT NULL REFERENCES paquete  ON DELETE CASCADE,
    id_materia   INT NOT NULL REFERENCES materia  ON DELETE CASCADE,
    id_profesor  INT NOT NULL REFERENCES profesor ON DELETE CASCADE,
    hora         INT NOT NULL,
    UNIQUE (id_paquete, id_materia),
    UNIQUE (id_paquete, hora),
    UNIQUE (id_profesor, hora)
);

CREATE OR REPLACE FUNCTION fn_formato_hora(p_hora INT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
    SELECT lpad(p_hora::TEXT, 2, '0') || '-' || lpad((p_hora + 1)::TEXT, 2, '0');
$$;

CREATE OR REPLACE FUNCTION fn_id_materia(p_clave VARCHAR)
RETURNS INT LANGUAGE plpgsql STABLE AS $$
DECLARE v_id INT;
BEGIN
    SELECT id_materia INTO v_id FROM materia WHERE clave = upper(trim(p_clave));
    IF NOT FOUND THEN RAISE EXCEPTION 'No existe la materia %', p_clave; END IF;
    RETURN v_id;
END; $$;

--limites del sistema
CREATE OR REPLACE FUNCTION fn_max_maestros()    RETURNS INT LANGUAGE sql IMMUTABLE AS $$ SELECT 50 $$;
CREATE OR REPLACE FUNCTION fn_max_materias()    RETURNS INT LANGUAGE sql IMMUTABLE AS $$ SELECT 26 $$;
CREATE OR REPLACE FUNCTION fn_max_prioridades() RETURNS INT LANGUAGE sql IMMUTABLE AS $$ SELECT 4 $$;

--valida que un texto no este vacio, no pase del largo maximo y solo tenga letras y numeros
CREATE OR REPLACE FUNCTION fn_validar_texto(p_texto VARCHAR, p_campo TEXT,
                                            p_max INT, p_espacios BOOLEAN DEFAULT FALSE)
RETURNS TEXT LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE v_texto TEXT := trim(coalesce(p_texto, ''));
BEGIN
    IF v_texto = '' THEN
        RAISE EXCEPTION 'El campo % es obligatorio', p_campo;
    END IF;
    IF length(v_texto) > p_max THEN
        RAISE EXCEPTION 'El campo % admite máximo % caracteres', p_campo, p_max;
    END IF;
    IF v_texto !~ (CASE WHEN p_espacios THEN '^[A-Za-z0-9 ]+$' ELSE '^[A-Za-z0-9]+$' END) THEN
        RAISE EXCEPTION 'El campo % solo admite letras (A-Z, a-z)%', p_campo,
            CASE WHEN p_espacios THEN ', números (0-9) y espacios' ELSE ' y números (0-9), sin espacios' END;
    END IF;
    RETURN v_texto;
END; $$;

--registra un maestro despues de validar sus datos y el limite de maestros
CREATE OR REPLACE FUNCTION fn_registrar_profesor(p_clave VARCHAR, p_nombre VARCHAR)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE v_id     INT;
        v_clave  TEXT := upper(fn_validar_texto(p_clave, 'Clave', 10));
        v_nombre TEXT := fn_validar_texto(p_nombre, 'Nombre', 30, TRUE);
BEGIN
    IF (SELECT count(*) FROM profesor) >= fn_max_maestros() THEN
        RAISE EXCEPTION 'Ya hay % maestros registrados, que es el máximo', fn_max_maestros();
    END IF;
    IF EXISTS (SELECT 1 FROM profesor WHERE clave = v_clave) THEN
        RAISE EXCEPTION 'Ya existe un maestro con la clave %', v_clave;
    END IF;

    INSERT INTO profesor(clave, nombre) VALUES (v_clave, v_nombre)
    RETURNING id_profesor INTO v_id;
    RETURN v_id;
END; $$;

--registra una materia despues de validar sus datos y el limite de materias
CREATE OR REPLACE FUNCTION fn_registrar_materia(p_clave VARCHAR, p_nombre VARCHAR, p_semestre INT)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE v_id     INT;
        v_clave  TEXT := upper(trim(coalesce(p_clave, '')));
        v_nombre TEXT := fn_validar_texto(p_nombre, 'Nombre', 30, TRUE);
BEGIN
    IF v_clave !~ '^[A-Z]$' THEN
        RAISE EXCEPTION 'La clave de la materia debe ser una sola letra (A-Z)';
    END IF;
    IF (SELECT count(*) FROM materia) >= fn_max_materias() THEN
        RAISE EXCEPTION 'Ya hay % materias registradas, que es el máximo', fn_max_materias();
    END IF;
    IF coalesce(p_semestre, 0) NOT BETWEEN 1 AND 8 THEN
        RAISE EXCEPTION 'El semestre debe estar entre 1 y 8';
    END IF;
    IF EXISTS (SELECT 1 FROM materia WHERE clave = v_clave) THEN
        RAISE EXCEPTION 'Ya existe una materia con la clave %', v_clave;
    END IF;

    INSERT INTO materia(clave, nombre, semestre) VALUES (v_clave, v_nombre, p_semestre)
    RETURNING id_materia INTO v_id;
    RETURN v_id;
END; $$;

--ajusta los grupos de un semestre: crea los que faltan y borra los que sobran
CREATE OR REPLACE FUNCTION fn_definir_grupos(p_semestre INT, p_num_grupos INT)
RETURNS INT LANGUAGE plpgsql AS $$
BEGIN
    IF coalesce(p_num_grupos, -1) NOT BETWEEN 0 AND 10 THEN
        RAISE EXCEPTION 'El número de grupos debe estar entre 0 y 10';
    END IF;
    IF p_num_grupos > 0 AND NOT EXISTS (SELECT 1 FROM materia WHERE semestre = p_semestre) THEN
        RAISE EXCEPTION 'No hay materias registradas en el semestre %', p_semestre;
    END IF;

    DELETE FROM paquete
    WHERE semestre = p_semestre AND ascii(grupo) - 64 > p_num_grupos;

    INSERT INTO paquete(semestre, grupo)
    SELECT p_semestre, chr(64 + n) FROM generate_series(1, p_num_grupos) n
    ON CONFLICT DO NOTHING;

    RETURN p_num_grupos;
END; $$;

--agrega una materia al final de la lista de prioridades del maestro
CREATE OR REPLACE FUNCTION fn_agregar_preferencia(p_profesor INT, p_materia INT)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE v_prioridad INT;
BEGIN
    IF EXISTS (SELECT 1 FROM preferencia WHERE id_profesor = p_profesor AND id_materia = p_materia) THEN
        RAISE EXCEPTION 'El maestro ya tiene esa materia en su lista';
    END IF;

    SELECT coalesce(max(prioridad), 0) + 1 INTO v_prioridad
    FROM preferencia WHERE id_profesor = p_profesor;

    IF v_prioridad > fn_max_prioridades() THEN
        RAISE EXCEPTION 'El maestro ya tiene % materias, que es el máximo', fn_max_prioridades();
    END IF;

    INSERT INTO preferencia(id_profesor, id_materia, prioridad) VALUES (p_profesor, p_materia, v_prioridad);
    RETURN v_prioridad;
END; $$;

--sube una materia un lugar en la lista de prioridades
CREATE OR REPLACE FUNCTION fn_subir_preferencia(p_profesor INT, p_materia INT)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE v_prioridad INT;
BEGIN
    SELECT prioridad INTO v_prioridad FROM preferencia
    WHERE id_profesor = p_profesor AND id_materia = p_materia;

    IF v_prioridad IS NULL THEN RAISE EXCEPTION 'Esa materia no está en la lista'; END IF;
    IF v_prioridad = 1     THEN RAISE EXCEPTION 'Esa materia ya es la prioridad 1'; END IF;

    UPDATE preferencia SET prioridad = v_prioridad
    WHERE id_profesor = p_profesor AND prioridad = v_prioridad - 1;
    UPDATE preferencia SET prioridad = v_prioridad - 1
    WHERE id_profesor = p_profesor AND id_materia = p_materia;

    RETURN v_prioridad - 1;
END; $$;

--quita una materia de la lista y recorre las prioridades que seguian
CREATE OR REPLACE FUNCTION fn_quitar_preferencia(p_profesor INT, p_materia INT)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE v_prioridad INT;
BEGIN
    DELETE FROM preferencia WHERE id_profesor = p_profesor AND id_materia = p_materia
    RETURNING prioridad INTO v_prioridad;

    IF v_prioridad IS NULL THEN RAISE EXCEPTION 'Esa materia no está en la lista'; END IF;

    UPDATE preferencia SET prioridad = prioridad - 1
    WHERE id_profesor = p_profesor AND prioridad > v_prioridad;
END; $$;

--reemplaza las horas disponibles del maestro
CREATE OR REPLACE FUNCTION fn_guardar_disponibilidad(p_profesor INT, p_horas INT[])
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE v_total INT;
BEGIN
    IF EXISTS (SELECT 1 FROM unnest(p_horas) h WHERE h NOT BETWEEN 7 AND 21) THEN
        RAISE EXCEPTION 'Las horas deben estar entre 07:00 y 22:00';
    END IF;

    DELETE FROM disponibilidad WHERE id_profesor = p_profesor;
    INSERT INTO disponibilidad(id_profesor, hora)
    SELECT DISTINCT p_profesor, h FROM unnest(p_horas) h;

    GET DIAGNOSTICS v_total = ROW_COUNT;
    RETURN v_total;
END; $$;

CREATE OR REPLACE FUNCTION fn_eliminar_profesor(p_profesor INT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM profesor WHERE id_profesor = p_profesor;
    IF NOT FOUND THEN RAISE EXCEPTION 'El maestro no existe'; END IF;
END; $$;

CREATE OR REPLACE FUNCTION fn_eliminar_materia(p_materia INT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM materia WHERE id_materia = p_materia;
    IF NOT FOUND THEN RAISE EXCEPTION 'La materia no existe'; END IF;
END; $$;

--grupos que requiere una materia, uno por cada paquete de su semestre
CREATE OR REPLACE FUNCTION fn_grupos_necesarios(p_materia INT)
RETURNS INT LANGUAGE sql STABLE AS $$
    SELECT count(*)::INT FROM paquete pq JOIN materia m ON m.semestre = pq.semestre
    WHERE m.id_materia = p_materia;
$$;

--grupos de una materia que ya tienen maestro y hora
CREATE OR REPLACE FUNCTION fn_grupos_asignados(p_materia INT)
RETURNS INT LANGUAGE sql STABLE AS $$
    SELECT count(*)::INT FROM clase WHERE id_materia = p_materia;
$$;

CREATE OR REPLACE FUNCTION fn_hora_libre_paquete(p_paquete INT, p_hora INT)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT NOT EXISTS (SELECT 1 FROM clase WHERE id_paquete = p_paquete AND hora = p_hora);
$$;

--primer paquete del semestre que tiene la hora libre y aun no tiene la materia
CREATE OR REPLACE FUNCTION fn_paquete_para(p_materia INT, p_hora INT)
RETURNS INT LANGUAGE sql STABLE AS $$
    SELECT pq.id_paquete
    FROM paquete pq JOIN materia m ON m.semestre = pq.semestre
    WHERE m.id_materia = p_materia
      AND fn_hora_libre_paquete(pq.id_paquete, p_hora)
      AND NOT EXISTS (SELECT 1 FROM clase c WHERE c.id_paquete = pq.id_paquete AND c.id_materia = p_materia)
    ORDER BY pq.grupo
    LIMIT 1;
$$;

--llena la tabla de opciones: cada hora disponible de cada maestro con cada materia que prefiere
CREATE OR REPLACE FUNCTION fn_crear_opciones()
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE v_total INT;
BEGIN
    DELETE FROM opcion;
    INSERT INTO opcion(id_profesor, hora, id_materia, prioridad)
    SELECT d.id_profesor, d.hora, p.id_materia, p.prioridad
    FROM disponibilidad d JOIN preferencia p ON p.id_profesor = d.id_profesor;

    GET DIAGNOSTICS v_total = ROW_COUNT;
    RETURN v_total;
END; $$;

--descarta las opciones de materias cubiertas, de horas en que el maestro ya tiene grupo
--y de horas sin paquete libre
CREATE OR REPLACE FUNCTION fn_depurar_opciones()
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
    v_n     INT;
    v_total INT := 0;
BEGIN
    UPDATE opcion SET estado = 'descartada'
    WHERE estado = 'pendiente'
      AND fn_grupos_asignados(id_materia) >= fn_grupos_necesarios(id_materia);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_total := v_total + v_n;

    UPDATE opcion o SET estado = 'descartada'
    WHERE o.estado = 'pendiente'
      AND EXISTS (SELECT 1 FROM clase c WHERE c.id_profesor = o.id_profesor AND c.hora = o.hora);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_total := v_total + v_n;

    UPDATE opcion SET estado = 'descartada'
    WHERE estado = 'pendiente'
      AND fn_paquete_para(id_materia, hora) IS NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_total := v_total + v_n;

    RETURN v_total;
END; $$;

--algoritmo principal: en cada vuelta depura las opciones y asigna la mejor segun las reglas
--de desempate; regresa los grupos asignados y las materias que quedaron pendientes
CREATE OR REPLACE FUNCTION fn_generar_paquetes()
RETURNS TABLE(tipo TEXT, descripcion TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    v_op      RECORD;
    v_paquete INT;
    v_nom_paq TEXT;
    v_mat     RECORD;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM paquete) THEN
        RAISE EXCEPTION 'Primero define cuántos grupos tiene cada semestre';
    END IF;

    DELETE FROM clase;
    PERFORM fn_crear_opciones();

    LOOP
        PERFORM fn_depurar_opciones();

        SELECT o.id_profesor, o.hora, o.id_materia, p.clave AS prof, m.clave AS mat,
               (SELECT count(*) FROM opcion x
                WHERE x.id_profesor = o.id_profesor AND x.estado = 'pendiente') AS restantes
        INTO v_op
        FROM opcion o
        JOIN profesor p ON p.id_profesor = o.id_profesor
        JOIN materia m  ON m.id_materia  = o.id_materia
        WHERE o.estado = 'pendiente'
        ORDER BY restantes, o.prioridad, o.hora, p.clave
        LIMIT 1;

        EXIT WHEN NOT FOUND;

        v_paquete := fn_paquete_para(v_op.id_materia, v_op.hora);
        SELECT semestre || grupo INTO v_nom_paq FROM paquete WHERE id_paquete = v_paquete;

        INSERT INTO clase(id_paquete, id_materia, id_profesor, hora)
        VALUES (v_paquete, v_op.id_materia, v_op.id_profesor, v_op.hora);

        UPDATE opcion SET estado = 'asignada'
        WHERE id_profesor = v_op.id_profesor AND hora = v_op.hora AND id_materia = v_op.id_materia;

        tipo := 'asignacion';
        descripcion := 'Materia ' || v_op.mat || ' de ' || fn_formato_hora(v_op.hora) ||
                       ' en el paquete ' || v_nom_paq || ' con el maestro ' || v_op.prof;
        RETURN NEXT;
    END LOOP;

    FOR v_mat IN
        SELECT m.clave, fn_grupos_asignados(m.id_materia) AS asig, fn_grupos_necesarios(m.id_materia) AS nec
        FROM materia m
        WHERE fn_grupos_asignados(m.id_materia) < fn_grupos_necesarios(m.id_materia)
        ORDER BY m.semestre, m.clave
    LOOP
        tipo := 'pendiente';
        descripcion := 'Queda pendiente la materia ' || v_mat.clave || ': ' || v_mat.asig || ' de ' ||
                       v_mat.nec || ' grupos registrados (ningún maestro disponible la puede cubrir)';
        RETURN NEXT;
    END LOOP;
END; $$;

--horas disponibles del maestro agrupadas en rangos continuos
CREATE OR REPLACE FUNCTION fn_disponibilidad_texto(p_profesor INT)
RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT coalesce(string_agg(lpad(ini::TEXT, 2, '0') || '-' || lpad((fin + 1)::TEXT, 2, '0'),
                               ', ' ORDER BY ini), 'Sin registrar')
    FROM (SELECT min(hora) AS ini, max(hora) AS fin
          FROM (SELECT hora, hora - ROW_NUMBER() OVER (ORDER BY hora) AS isla
                FROM disponibilidad WHERE id_profesor = p_profesor) t
          GROUP BY isla) r;
$$;

CREATE OR REPLACE FUNCTION fn_preferencias_texto(p_profesor INT)
RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT coalesce(string_agg(m.clave, ', ' ORDER BY p.prioridad), 'Sin registrar')
    FROM preferencia p JOIN materia m ON m.id_materia = p.id_materia
    WHERE p.id_profesor = p_profesor;
$$;

CREATE OR REPLACE FUNCTION fn_listar_profesores()
RETURNS TABLE(id INT, clave TEXT, nombre TEXT, disponibilidad TEXT, prioridades TEXT, grupos INT)
LANGUAGE sql STABLE AS $$
    SELECT p.id_profesor, p.clave::TEXT, p.nombre::TEXT,
           fn_disponibilidad_texto(p.id_profesor), fn_preferencias_texto(p.id_profesor),
           (SELECT count(*) FROM clase c WHERE c.id_profesor = p.id_profesor)::INT
    FROM profesor p ORDER BY p.clave;
$$;

CREATE OR REPLACE FUNCTION fn_datos_profesor(p_profesor INT)
RETURNS TABLE(id INT, clave TEXT, nombre TEXT, disponibilidad TEXT)
LANGUAGE sql STABLE AS $$
    SELECT id_profesor, clave::TEXT, nombre::TEXT, fn_disponibilidad_texto(id_profesor)
    FROM profesor WHERE id_profesor = p_profesor;
$$;

CREATE OR REPLACE FUNCTION fn_horas_profesor(p_profesor INT)
RETURNS TABLE(hora INT) LANGUAGE sql STABLE AS $$
    SELECT hora FROM disponibilidad WHERE id_profesor = p_profesor ORDER BY hora;
$$;

CREATE OR REPLACE FUNCTION fn_preferencias_profesor(p_profesor INT)
RETURNS TABLE(prioridad INT, id_materia INT, clave TEXT, materia TEXT, semestre INT)
LANGUAGE sql STABLE AS $$
    SELECT p.prioridad, m.id_materia, m.clave::TEXT, m.nombre::TEXT, m.semestre
    FROM preferencia p JOIN materia m ON m.id_materia = p.id_materia
    WHERE p.id_profesor = p_profesor ORDER BY p.prioridad;
$$;

CREATE OR REPLACE FUNCTION fn_horario_profesor(p_profesor INT)
RETURNS TABLE(horario TEXT, paquete TEXT, clave TEXT, materia TEXT)
LANGUAGE sql STABLE AS $$
    SELECT fn_formato_hora(c.hora), pq.semestre || pq.grupo, m.clave::TEXT, m.nombre::TEXT
    FROM clase c
    JOIN materia m  ON m.id_materia  = c.id_materia
    JOIN paquete pq ON pq.id_paquete = c.id_paquete
    WHERE c.id_profesor = p_profesor ORDER BY c.hora;
$$;

CREATE OR REPLACE FUNCTION fn_listar_materias()
RETURNS TABLE(id INT, clave TEXT, nombre TEXT, semestre INT, grupos INT, asignados INT, interesados INT)
LANGUAGE sql STABLE AS $$
    SELECT m.id_materia, m.clave::TEXT, m.nombre::TEXT, m.semestre,
           fn_grupos_necesarios(m.id_materia), fn_grupos_asignados(m.id_materia),
           (SELECT count(*) FROM preferencia p WHERE p.id_materia = m.id_materia)::INT
    FROM materia m ORDER BY m.semestre, m.clave;
$$;

CREATE OR REPLACE FUNCTION fn_listar_semestres()
RETURNS TABLE(semestre INT, materias INT, grupos INT)
LANGUAGE sql STABLE AS $$
    SELECT m.semestre, count(*)::INT,
           (SELECT count(*) FROM paquete pq WHERE pq.semestre = m.semestre)::INT
    FROM materia m GROUP BY m.semestre ORDER BY m.semestre;
$$;

--horas que aparecen en la disponibilidad de algun maestro
CREATE OR REPLACE FUNCTION fn_horas_trabajo()
RETURNS TABLE(hora INT) LANGUAGE sql STABLE AS $$
    SELECT DISTINCT hora FROM disponibilidad ORDER BY hora;
$$;

--clases asignadas en los paquetes de un semestre
CREATE OR REPLACE FUNCTION fn_horario_semestre(p_semestre INT)
RETURNS TABLE(hora INT, grupo TEXT, clave TEXT, materia TEXT, profesor TEXT)
LANGUAGE sql STABLE AS $$
    SELECT c.hora, pq.grupo::TEXT, m.clave::TEXT, m.nombre::TEXT, p.clave::TEXT
    FROM clase c
    JOIN paquete pq ON pq.id_paquete = c.id_paquete
    JOIN materia m  ON m.id_materia  = c.id_materia
    JOIN profesor p ON p.id_profesor = c.id_profesor
    WHERE pq.semestre = p_semestre
    ORDER BY c.hora, pq.grupo;
$$;

CREATE OR REPLACE FUNCTION fn_grupos_semestre(p_semestre INT)
RETURNS TABLE(grupo TEXT) LANGUAGE sql STABLE AS $$
    SELECT grupo::TEXT FROM paquete WHERE semestre = p_semestre ORDER BY grupo;
$$;

--trigger que impide registrar una clase invalida, aunque el insert se haga directamente
CREATE OR REPLACE FUNCTION fn_validar_clase()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM disponibilidad WHERE id_profesor = NEW.id_profesor AND hora = NEW.hora) THEN
        RAISE EXCEPTION 'El maestro no está disponible de %', fn_formato_hora(NEW.hora);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM preferencia WHERE id_profesor = NEW.id_profesor AND id_materia = NEW.id_materia) THEN
        RAISE EXCEPTION 'El maestro no tiene esa materia en sus prioridades';
    END IF;
    IF (SELECT semestre FROM materia WHERE id_materia = NEW.id_materia)
       <> (SELECT semestre FROM paquete WHERE id_paquete = NEW.id_paquete) THEN
        RAISE EXCEPTION 'La materia no pertenece al semestre del paquete';
    END IF;
    IF fn_grupos_asignados(NEW.id_materia) >= fn_grupos_necesarios(NEW.id_materia) THEN
        RAISE EXCEPTION 'La materia ya tiene todos sus grupos registrados';
    END IF;
    RETURN NEW;
END; $$;

CREATE TRIGGER trg_validar_clase BEFORE INSERT ON clase
FOR EACH ROW EXECUTE FUNCTION fn_validar_clase();

--datos de ejemplo, registrados por medio de las funciones
DO $$
DECLARE
    v_prof INT;
    r      RECORD;
    v_mat  TEXT;
BEGIN
    PERFORM fn_registrar_materia('A', 'Materia A', 1);
    PERFORM fn_registrar_materia('C', 'Materia C', 1);
    PERFORM fn_registrar_materia('F', 'Materia F', 1);
    PERFORM fn_registrar_materia('J', 'Materia J', 1);
    PERFORM fn_registrar_materia('B', 'Materia B', 2);
    PERFORM fn_registrar_materia('D', 'Materia D', 2);
    PERFORM fn_registrar_materia('G', 'Materia G', 2);
    PERFORM fn_registrar_materia('H', 'Materia H', 2);
    PERFORM fn_registrar_materia('E', 'Materia E', 3);
    PERFORM fn_registrar_materia('I', 'Materia I', 3);
    PERFORM fn_registrar_materia('K', 'Materia K', 3);
    PERFORM fn_registrar_materia('L', 'Materia L', 3);

    PERFORM fn_definir_grupos(1, 3);
    PERFORM fn_definir_grupos(2, 2);
    PERFORM fn_definir_grupos(3, 1);

    FOR r IN
        SELECT * FROM (VALUES
            ('M001', 'Maestro 1',  ARRAY[8, 9, 10, 11], ARRAY['A', 'B', 'E']),
            ('M002', 'Maestro 2',  ARRAY[9, 10, 11],    ARRAY['C', 'D', 'K', 'L']),
            ('M003', 'Maestro 3',  ARRAY[8, 10],        ARRAY['H', 'I']),
            ('M004', 'Maestro 4',  ARRAY[8, 9],         ARRAY['F', 'G']),
            ('M005', 'Maestro 5',  ARRAY[8, 9, 10, 11], ARRAY['B', 'E']),
            ('M006', 'Maestro 6',  ARRAY[10, 11],       ARRAY['G', 'F']),
            ('M007', 'Maestro 7',  ARRAY[8, 9, 10],     ARRAY['L', 'K']),
            ('M008', 'Maestro 8',  ARRAY[8, 9],         ARRAY['J']),
            ('M009', 'Maestro 9',  ARRAY[8, 9, 10, 11], ARRAY['A', 'C', 'D']),
            ('M010', 'Maestro 10', ARRAY[8, 9, 10, 11], ARRAY['H', 'I', 'J'])
        ) AS t(clave, nombre, horas, materias)
    LOOP
        v_prof := fn_registrar_profesor(r.clave, r.nombre);
        PERFORM fn_guardar_disponibilidad(v_prof, r.horas);
        FOREACH v_mat IN ARRAY r.materias LOOP
            PERFORM fn_agregar_preferencia(v_prof, fn_id_materia(v_mat));
        END LOOP;
    END LOOP;
END $$;