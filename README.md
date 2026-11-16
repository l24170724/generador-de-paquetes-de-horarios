# Generador de paquetes de horarios

Proyecto final de Taller de Bases de Datos. Arma los horarios de cada grupo a partir de las materias
que prefiere cada maestro y de las horas en que puede trabajar. Toda la lógica está en funciones de
PostgreSQL y la página web está hecha en Python con Flask.

## Requisitos
- Python 3.10 o más reciente
- PostgreSQL 16 o 17

## Instalación
1. Instalar las librerías: `pip install flask psycopg2-binary`
2. Escribir la contraseña de PostgreSQL en `app.py`, en la línea `"password"`.
3. Crear la base de datos con los datos de ejemplo: `python app.py instalar`
4. Iniciar la página: `python app.py`
5. Abrir en el navegador: http://127.0.0.1:5000

## Archivos
- `base_datos.sql`: tablas, funciones, trigger y datos de ejemplo
- `app.py`: página web y conexión con PostgreSQL
- `templates/`: pantallas de la página
