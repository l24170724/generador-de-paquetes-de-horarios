import sys

import psycopg2
from psycopg2.extras import RealDictCursor
from flask import Flask, render_template, request, redirect, url_for, flash

CONFIG = {
    "host": "localhost",
    "port": 5432,
    "dbname": "paquetes",
    "user": "postgres",
    "password": "postgres",
}

HORAS = list(range(7, 22))

app = Flask(__name__)
app.secret_key = "generador-paquetes"


#abre la conexion con postgresql; si la contrasena es incorrecta muestra un mensaje claro
def conectar(dbname=None):
    datos = {**CONFIG, "dbname": dbname or CONFIG["dbname"]}
    try:
        return psycopg2.connect(**datos)
    except UnicodeDecodeError:
        raise SystemExit("No se pudo conectar a PostgreSQL: la contraseña es incorrecta.\n"
                         "Revisa \"password\" en CONFIG, al inicio de app.py.")


#ejecuta una funcion de postgresql que regresa un solo valor
def llamar(funcion, *params):
    return _ejecutar(f"SELECT {funcion}({', '.join(['%s'] * len(params))})", params, uno=True)


#ejecuta una funcion de postgresql que regresa una tabla
def tabla(funcion, *params):
    return _ejecutar(f"SELECT * FROM {funcion}({', '.join(['%s'] * len(params))})", params)


#ejecuta la consulta y confirma los cambios, o los revierte si hay error
def _ejecutar(sql, params, uno=False):
    con = conectar()
    try:
        with con.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(sql, params)
            resultado = list(cur.fetchone().values())[0] if uno else cur.fetchall()
        con.commit()
        return resultado
    except Exception:
        con.rollback()
        raise
    finally:
        con.close()


#obtiene el mensaje del raise exception de postgresql
def mensaje_error(e):
    if isinstance(e, psycopg2.Error) and e.diag.message_primary:
        return e.diag.message_primary
    return str(e)


#llama una funcion y muestra en la pagina el aviso de exito o de error
def ejecutar(funcion, *params, exito=None):
    try:
        resultado = llamar(funcion, *params)
        if exito:
            flash(exito.format(resultado), "ok")
        return resultado
    except Exception as e:
        flash(mensaje_error(e), "error")
        return None


#convierte un campo del formulario a entero; regresa none si esta vacio o es invalido
def entero(campo):
    try:
        return int(request.form.get(campo, ""))
    except ValueError:
        return None


#crea la base de datos si no existe y ejecuta base_datos.sql
def instalar():
    admin = conectar("postgres")
    admin.autocommit = True
    with admin.cursor() as cur:
        cur.execute("SELECT 1 FROM pg_database WHERE datname = %s", (CONFIG["dbname"],))
        if cur.fetchone() is None:
            cur.execute(f'CREATE DATABASE {CONFIG["dbname"]}')
            print(f"Base de datos '{CONFIG['dbname']}' creada")
    admin.close()

    con = conectar()
    with con, con.cursor() as cur, open("base_datos.sql", encoding="utf-8") as f:
        cur.execute(f.read())
    con.close()
    print("OK  base_datos.sql (tablas, funciones y datos de ejemplo)")
    print("Listo. Ahora ejecuta:  python app.py")


#filtro para mostrar las horas en las plantillas
@app.template_filter("hora")
def formato_hora(h):
    return f"{h:02d}-{h + 1:02d}"


#pagina principal: grupos por semestre y horario de cada paquete
@app.route("/")
def inicio():
    semestres = tabla("fn_listar_semestres")
    horas = [r["hora"] for r in tabla("fn_horas_trabajo")]

    paquetes = []
    for s in semestres:
        grupos = [g["grupo"] for g in tabla("fn_grupos_semestre", s["semestre"])]
        if grupos:
            celdas = {(c["hora"], c["grupo"]): c for c in tabla("fn_horario_semestre", s["semestre"])}
            paquetes.append({"semestre": s["semestre"], "grupos": grupos, "celdas": celdas})

    materias = tabla("fn_listar_materias")
    return render_template("paquetes.html", semestres=semestres, materias=materias,
                           paquetes=paquetes, horas=horas,
                           generado=any(m["asignados"] for m in materias))


@app.post("/grupos")
def definir_grupos():
    ejecutar("fn_definir_grupos", entero("semestre"), entero("grupos"), exito="Grupos actualizados: {}")
    return redirect(url_for("inicio"))


#ejecuta el algoritmo y muestra los grupos asignados y las materias pendientes
@app.post("/generar")
def generar():
    try:
        pasos = tabla("fn_generar_paquetes")
        asignados = sum(1 for p in pasos if p["tipo"] == "asignacion")
        flash(f"Paquetes generados: {asignados} grupos registrados", "ok")
        for p in pasos:
            if p["tipo"] == "pendiente":
                flash(p["descripcion"], "error")
    except Exception as e:
        flash(mensaje_error(e), "error")
    return redirect(url_for("inicio"))


@app.route("/profesores")
def profesores():
    return render_template("maestros.html", profesores=tabla("fn_listar_profesores"),
                           max_maestros=llamar("fn_max_maestros"))


@app.post("/profesores/nuevo")
def nuevo_profesor():
    id = ejecutar("fn_registrar_profesor", request.form.get("clave"), request.form.get("nombre"),
                  exito="Maestro registrado")
    return redirect(url_for("ver_profesor", id=id) if id else url_for("profesores"))


#ficha del maestro: prioridades, horario disponible y grupos asignados
@app.route("/profesores/<int:id>")
def ver_profesor(id):
    datos = tabla("fn_datos_profesor", id)
    if not datos:
        flash("Ese maestro no existe", "error")
        return redirect(url_for("profesores"))
    preferencias = tabla("fn_preferencias_profesor", id)
    elegidas = {p["id_materia"] for p in preferencias}
    return render_template(
        "maestros.html", prof=datos[0], preferencias=preferencias,
        materias=[m for m in tabla("fn_listar_materias") if m["id"] not in elegidas],
        mis_horas={h["hora"] for h in tabla("fn_horas_profesor", id)},
        horario=tabla("fn_horario_profesor", id), horas=HORAS,
        max_prioridades=llamar("fn_max_prioridades"))


@app.post("/profesores/<int:id>/preferencia")
def agregar_preferencia(id):
    ejecutar("fn_agregar_preferencia", id, entero("materia"), exito="Materia agregada con prioridad {}")
    return redirect(url_for("ver_profesor", id=id))


@app.post("/profesores/<int:id>/preferencia/<int:materia>/subir")
def subir_preferencia(id, materia):
    ejecutar("fn_subir_preferencia", id, materia)
    return redirect(url_for("ver_profesor", id=id))


@app.post("/profesores/<int:id>/preferencia/<int:materia>/quitar")
def quitar_preferencia(id, materia):
    ejecutar("fn_quitar_preferencia", id, materia, exito="Materia quitada")
    return redirect(url_for("ver_profesor", id=id))


@app.post("/profesores/<int:id>/disponibilidad")
def guardar_disponibilidad(id):
    horas = [int(h) for h in request.form.getlist("horas")]
    ejecutar("fn_guardar_disponibilidad", id, horas, exito="Se guardaron {} horas disponibles")
    return redirect(url_for("ver_profesor", id=id))


@app.post("/profesores/<int:id>/eliminar")
def eliminar_profesor(id):
    ejecutar("fn_eliminar_profesor", id, exito="Maestro eliminado")
    return redirect(url_for("profesores"))


@app.route("/materias")
def materias():
    return render_template("materias.html", materias=tabla("fn_listar_materias"),
                           max_materias=llamar("fn_max_materias"))


@app.post("/materias/nueva")
def nueva_materia():
    ejecutar("fn_registrar_materia", request.form.get("clave"), request.form.get("nombre"),
             entero("semestre"), exito="Materia registrada")
    return redirect(url_for("materias"))


@app.post("/materias/<int:id>/eliminar")
def eliminar_materia(id):
    ejecutar("fn_eliminar_materia", id, exito="Materia eliminada")
    return redirect(url_for("materias"))


#con el argumento instalar crea la base; sin argumentos inicia la pagina
if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "instalar":
        instalar()
    else:
        app.run(debug=True)
