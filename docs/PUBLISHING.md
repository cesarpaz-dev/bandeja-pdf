# Preparar la publicación en GitHub

Repositorio oficial: [cesarpaz-dev/bandeja-pdf](https://github.com/cesarpaz-dev/bandeja-pdf). Esta guía describe la revisión del contenido y el flujo para publicar cambios posteriores o preparar una copia en otra cuenta.

El repositorio publicable es **`bandeja-pdf/`**. La carpeta de trabajo que pueda contenerlo también puede incluir herramientas antiguas y archivos privados; no debe subirse como un conjunto.

## Contenido

Se publican código propio, pruebas sintéticas, documentación, recursos de la app y scripts. La licencia elegida es [AGPL-3.0-only](../LICENSE). Los avisos de dependencias están en [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).

Se excluyen `local/`, `phase0/`, `phase1/`, resultados de pruebas, runtime, paquetes compilados, documentos y capturas. Los originales históricos permanecen en el equipo y no se borran al organizar el repositorio.

## Revisión local

Desde la raíz del repositorio:

```sh
python3 scripts/check-public-tree.py
git status --short
git diff --check
```

El auditor incluye archivos ya seguidos por Git y candidatos no ignorados. Comprueba estructura, tipos de archivo, patrones reconocibles de datos locales/credenciales y enlaces de documentación. No sustituye una revisión humana ni detecta cualquier secreto posible. `.gitignore` por sí solo no retira archivos ya incorporados a Git.

Después de revisar, preparar el primer commit:

```sh
git add README.md LICENSE CHANGELOG.md CONTRIBUTING.md THIRD_PARTY_NOTICES.md
git add .gitignore .gitattributes .editorconfig requirements-dev.txt docs native scripts .github
python3 scripts/check-public-tree.py
git diff --cached --check
git diff --cached --stat
git commit -m "Prepare Bandeja PDF source project"
```

Revisar también el nombre y correo de autor configurados en Git antes del commit. No añadir archivos ignorados con `git add -f` ni subir un ZIP de toda la carpeta de trabajo.

## Repositorio remoto

El repositorio oficial ya existe. Para conectar una copia local que todavía no tenga `origin`, usar:

```sh
git remote add origin https://github.com/cesarpaz-dev/bandeja-pdf.git
git push -u origin main
```

Si ya existe `origin`, comprobarlo con `git remote -v` antes de publicar. Para una copia independiente, crear un repositorio vacío en la cuenta elegida y utilizar su propia URL. Estos pasos publican el contenido y se realizan después de revisar el commit.

Tras el primer envío, comprobar el resultado de GitHub Actions y la navegación de los documentos. No crear una release con el `.app` local hasta completar los requisitos de [distribución](ROADMAP.md).
